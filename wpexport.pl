#! /usr/bin/perl

#
# Script to get wikipedia pages and prepare them for merging with encoresoup.
#
# Usage: perl wpexport.pl [--merge] [--file <file>] [--page <page title>]
# Options:
#   --merge     Retrieves matching pages from encoresoup into es.txt to facilitate manual merging.
#   --file      Specifies File containing list of page titles, one per line.
#   --page      Specifies Page Title to retrieve.
#   --allpages	Retrieve list of all pages from Encoresoup and use it in place of --file
#   --imagehash Image files will be downloaded to subdirectories based on MD5
#               hash on filename. (mirroring structure expected by mediawiki
#               software - not really useful for non-admins)
#   --getimages Image pages and files linked from current page will also be
#               downloaded.
#   --redirects Export redirects pointing to required pages.
#
#   One of --file, --page or --allpages must be supplied
#
#   Output is one or more text files in suitable format for pywikipedia's pagefromfile script.  If pages
#   from the Image namespace are specified, the image files will also be created in the 'images' subdirectory.
#
#   Output files (will be overwritten if they already exist!):
#
#     wp.txt       Main output file containing main page text.
#     es.txt       Matching page text from Encoresoup (only created if --merge option is used)
#                     These two files can then be merged using e.g. kdiff3.
#                      
#
# Copyright (C) 2008 David Claughton <dave@encoresoup.net>
# http://encoresoup.net/
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
# http://www.gnu.org/copyleft/gpl.html
# 

use strict;

use File::Basename;
use File::Slurp;
use LWP::UserAgent;
use XML::Twig;
use Text::Balanced qw ( extract_bracketed );
use Date::Manip;
use Getopt::Long;
use MD5;
use Term::ProgressBar;
use MediaWiki::API;
use DBI;
use URI::Escape;
use Encode;

binmode STDOUT, ':utf8';
$| = 1;

# Hashref storing site information.
my $sites;

my %tmplflds;
#my %meta;

my $script=basename($0);
my $usage="Usage: $script [--<opts>]";

my %opts;
Getopt::Long::Configure("bundling");
GetOptions (\%opts,
	'db=s',
	'site=s',
  'merge',
	'imagehash',
	'getimages',
  'file=s',
  'page=s',
	'redirects',
	'allpages',
	'export-updated|export',
	'export-all',
	'status',
	'delete',
	'update',
	'relink-images',
	'nocontrib',
	'import',
	'start=s'
) or die("$usage\nInvalid Option\n");

die ("Must specify site!\n") unless defined $opts{site} || defined $opts{status};

map { $opts{$_} = 0 if !exists($opts{$_}) } qw/merge imagehash getimages redirects allpages delete status update relink-images nocontrib import/;

# Create a user agent object
my $ua = LWP::UserAgent->new;
$ua->agent("WPExport/0.1 ");

# Create MediaWiki::API objects
my $esobj = MediaWiki::API->new( { api_url => 'http://encoresoup.net/api.php' } );

my $dbname = $opts{db} || 'wpexport.db';

# Connect to local SQLite datacache
my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");

# Cache 'sites' table into hashref
$sites = $dbh->selectall_hashref("select * from sites", 'name');

my $siteinfo = $dbh->selectrow_hashref("select * from sites where name = '$opts{site}'");

if ($opts{status}) {
	print_status();
	exit 0;
}

if ($opts{update}) {
	update_pages($opts{site});
	exit 0;
}

if ($opts{'relink-images'}) {
	relink_images($opts{site});
	exit 0;
}

if ($opts{import}) {
	import_pages($opts{site});
	exit 0;
}

my @pages;
if ($opts{file}) {
	@pages = map { chomp;  s/^\s*//; s/\s*$//; $_ } read_file($opts{file});
}
elsif ($opts{page}) {
	@pages = ($opts{page});
}
elsif ($opts{allpages}) {
	@pages = allpages();
}
elsif (!$opts{'export-updated'} && !$opts{'export-all'}) {
	print STDERR "Either --file, --page or --allpages must be supplied\n\n";
}

my $keeplinks = $dbh->selectall_arrayref(
 "select title from pages where site_id = 1 union select title from redirects where site_id = 1"
);

my %keeplinks = map { lc $_->[0] => 1 } (@$keeplinks);

if ($opts{delete}) {
	while (my $page = shift @pages) {
		delete_page($opts{site}, $page);
	}
	exit 0;
}

if (!@pages) {
	if ($opts{'export-updated'}) {
		export_pages({site => uc $opts{site}, updated => 1});
		exit 0;
	}
	elsif ($opts{'export-all'}) {
		export_pages({site => uc $opts{site}, updated => 0});
		exit 0;
	}
}

# while loop - allows for additional pages to be pushed onto the end of @pages;
while (my $page = shift @pages) {
	if ($opts{'export-updated'}) {
		export_pages({site => uc $opts{site}, page => $page, updated => 1});
		exit 0;
	}
	elsif ($opts{'export-all'}) {
		export_pages({site => uc $opts{site}, page => $page, updated => 0});
		exit 0;
	}
	else {
		# Reset 'updated' flags
		$dbh->do("update pages set updated = 0");

		process_page($opts{site}, $page);
	}
}

$dbh->disconnect();
exit 0;

sub process_page
{
	my $site = shift;
	my $page = shift;
	my $parent_page_id = shift;
	my $parent_page = shift;

	my $isimage;
	my $filter;
	my $orig_page_name;

	undef %tmplflds;

	chomp $page;

	print "Processing Page: $page\n";

	$isimage = ($page =~ /^Image:/i) ? 1 : 0;

	print "\tExporting From " . $siteinfo->{desc} . "\n";
	my %meta;
	my $text = get_page($site, $page, \%meta);
	if (exists $meta{missing}) {
		# check if 'missing' attribute is set. Usually happens for images
		# - indicates image description is on Wikimedia Commons.
		print "\tExporting From Wikimedia Commons\n";
		$site = 'CO';
		my $text = get_page($site, $page, \%meta);
	}

	# No such page!
	if (exists $meta{missing}) {
		print "\tPage Does Not Exist: $page\n";
		return;
	}

	if ($page ne $meta{realpage}) {
		print "\tActual Page Title: $meta{realpage}\n";
		$orig_page_name = $page;
		$page = $meta{realpage};
	}

	get_infobox_fields($text) if defined $text;

	my $page_id = store_page($dbh, $site, $page, $text, \%tmplflds, $parent_page_id, $parent_page, \%meta);

	# page_id will be zero if page already exists and does not need updating.
	if ($page_id && ($site ne 'ES')) {
		# Try to locate equivalent page on Encoresoup
		my $link_page_id = link_matching_page($dbh, $site, $page, $page_id);
		print "\tPage Linked to $page (id = $page_id) is id $link_page_id\n";

		$text = process_text($page, $text, $link_page_id);
		store_revision($dbh, $sites->{$site}{id}, $page_id, 'ESMERGE', $text, \%meta);

		# Do Wikipedia Revision Info Export
		get_contributors($site, $page, $page_id) unless $opts{nocontrib};
	}
	else {
		# Get the existing page for child pages to link to.
		$page_id = $meta{existing_page_id};
		$text = existing_page_text($page_id);
		get_infobox_fields($text) if defined $text;
	}

	if (($tmplflds{frequently_updated} =~ /yes/i) || ($site eq 'ES')){
		my $text; # Shield outer $text;

		print "\tNEED TO GET VERSION TEMPLATE!!\n\n" unless $site eq 'ES';

		undef %tmplflds;
		undef %meta;
		my $tmpl_page = "Template:Latest stable release/$page";
		my $text = get_page($site, "$tmpl_page", \%meta);
		if (!exists $meta{missing} && !exists $meta{uptodate}) {
			my $ib = extract_bracketed("$text", '{}'); # Quote $text variable to prevent modification.
			get_template_fields($ib);

			$tmpl_page = $meta{realpage} if defined $meta{realpage};
			print "Storing '$tmpl_page'\n";
			my $tmpl_page_id = store_page($dbh, $site, $tmpl_page, $text, \%tmplflds, $page_id, $page, \%meta);

			if ($tmplflds{template} ne 'Release') {
				my $latest_release_version = $tmplflds{latest_release_version};
				my $latest_release_date = $tmplflds{latest_release_date};

				my $text = create_release_template($site, $page, 'Latest_stable_release', $latest_release_version, $latest_release_date, $page_id);
				store_revision($dbh, $sites->{$site}{id}, $tmpl_page_id, 'ESMERGE', $text, \%meta);
			}
		}

		undef %tmplflds;
		undef %meta;
		my $tmpl_page = "Template:Latest preview release/$page";
		$text = get_page($site, $tmpl_page, \%meta);
		if (!exists $meta{missing} && !exists $meta{uptodate}) {
			my $ib = extract_bracketed("$text", '{}'); # Quote $text variable to prevent modification.
			get_template_fields($ib);

			$tmpl_page = $meta{realpage} if defined $meta{realpage};
			print "Storing '$tmpl_page'\n";
			my $tmpl_page_id = store_page($dbh, $site, $tmpl_page, $text, \%tmplflds, $page_id, $page, \%meta);

			if ($tmplflds{template} ne 'Release') {
				my $latest_release_version = $tmplflds{latest_release_version};
				my $latest_release_date = $tmplflds{latest_release_date};

				my $text = create_release_template($site, $page, 'Latest_preview_release', $latest_release_version, $latest_release_date, $page_id);
				store_revision($dbh, $sites->{$site}{id}, $tmpl_page_id, 'ESMERGE', $text, \%meta);
			}
		}
	}
	else {
		# Need to create some version templates, if appropriate infobox fields exist
		if ($tmplflds{template} =~ /infobox/i) {
			my ($latest_release_version, $latest_release_date, $latest_preview_version, $latest_preview_date);

			$latest_release_version = $tmplflds{latest_release_version};
			$latest_release_date = $tmplflds{latest_release_date};
			$latest_preview_version = $tmplflds{latest_preview_version};
			$latest_preview_date = $tmplflds{latest_preview_date};

			if ($latest_release_version) {
				my $text = create_release_template($site, $page, 'Latest_stable_release', $latest_release_version, $latest_release_date, $page_id);
				my ($tmpl_page_id, $last_revid) = page_in_cache($site, "Template:Latest_stable_release/$page");
				store_page($dbh, $site, "Template:Latest_stable_release/$page", $text, undef, $page_id, $page, { existing_page_id => $tmpl_page_id });
			}
			if ($latest_preview_version) {
				my $text = create_release_template($site, $page, 'Latest_preview_release', $latest_preview_version, $latest_preview_date, $page_id);
				my ($tmpl_page_id, $last_revid) = page_in_cache($site, "Template:Latest_preview_release/$page");
				store_page($dbh, $site, "Template:Latest_preview_release/$page", $text, undef, $page_id, $page, { existing_page_id => $tmpl_page_id });
			}
		}
	}

	# Identify Images
	if ($text && $opts{getimages}) {
		my $nocomments = $text;
		$nocomments =~ s/<!--.*?-->//g;
		my @images = ($nocomments =~ /\[\[(Image:[^\#\|\]]+)/gi);
		map { s/[^[:ascii:]]+//g; s/<!--.*?-->//g; process_page($site, $_, $page_id, $page); } @images;
	}

	# If we are getting a Image: page, then go get the corresponding image file
	my $image_src;
	$image_src = get_image($page) if ($isimage && $page_id && ($site ne 'ES'));

	# Add redirects
	if ($opts{redirects}) {
		print "\tCreating Redirect Pages\n";
		my @redirs = get_redirects($page,$site,1);
		push @redirs, $orig_page_name if defined $orig_page_name;
		map { create_redirect_text($page, $site, $_) } @redirs;
	}
}

sub get_contributors
{
	my $site = shift;
	my $page = shift;
	my $page_id = shift;

	my $contrib_page = $page;
	#$contrib_page =~ s/:/ /g;
	$contrib_page = "Template:WPContrib/$contrib_page";

	my $text;
	my %meta;

	print "\tExporting Contributors from " . $sites->{$site}{desc} . "...\n";

	if ($site eq 'ES') {
		$text = get_page($site, $contrib_page, \%meta);
		return if (exists $meta{missing} || exists $meta{uptodate});
	}
	else {
		my %contribs;

		my $url = "http://" . $sites->{$site}{url} . "/api.php";
		my $q = "action=query&prop=revisions&titles=$page&rvlimit=max&rvprop=user&format=xml";
		my $xml = do_query($url, $q);
		my $revstartid = parse_rev_xml($xml, \%contribs);
		while($revstartid != 0) {
			$xml = do_query($url, $q . '&rvstartid=' . $revstartid);
			$revstartid = parse_rev_xml($xml, \%contribs);
		}

		my $linkpage = $page;
		$linkpage = ':' . $page if $page =~ /^Image:/i;

		$text = <<EOF
== $page - Wikipedia Contributors ==

''The following people have contributed to the [[$linkpage]] article on Wikipedia, prior to it being imported into Encoresoup''
<div class=\"references-small\" style=\"-moz-column-count:3; -webkit-column-count:3; column-count:3;\">
EOF
;

		$text .= '*' . join("\n*", map { (/^[\d\.]*$/) ? "[[w:Special:Contributions/$_|$_]]" : "[[w:User:$_|$_]]" } sort(keys(%contribs)));
		$text .= "\n</div>\n";
	}

	print "Storing $contrib_page\n";
	my ($contrib_page_id, $last_revid) = page_in_cache($site, $contrib_page);
	$meta{existing_page_id} = $contrib_page_id;
	store_page($dbh, $site, $contrib_page, $text, undef, $page_id, $page, \%meta);
}

sub parse_export_xml
{
	my $xml = shift;
	my $meta = shift; # Must be a reference;

	my $title;
	my $text;
	my $revid;
	my $revts;
	my $missing = 0;

	my %pages;

	my $twig = XML::Twig->new(
	 	twig_handlers =>
			{ 
			  'revisions/rev' => sub
					{
						$text = $_->text;
						$revid = $_->atts->{revid};
						$revts = $_->atts->{timestamp};
					},
				'page' => sub
					{ 
						$title = $_->att('title');

						# If missing attribute set, then discard this page and return undef.
						if (exists $_->atts->{missing}) {
							$meta->{missing} = 1 if defined $meta;
						}
					}
			},
		pretty_print => 'indented'
	);
	$twig->parse($xml);

	if (defined $meta) {
		$meta->{realpage} = $title;
		$meta->{revid} = $revid;
		$meta->{revts} = $revts;
	}

	return $text;
}

sub parse_rev_xml
{
	my $xml = shift;
	my $contribref = shift;

	my $user = "";
	my $revstartid = 0;

	my $twig = XML::Twig->new(
	 	twig_handlers =>
			{ 'revisions/rev' => sub
					{ 
						$user = $_->att('user');
						$contribref->{$user} = 1;
					},
			  'query-continue/revisions' => sub
					{ 
						$revstartid = $_->att('rvstartid');
					}
			},
		pretty_print => 'indented'
	);
	$twig->parse($xml);

	return $revstartid;
}

sub process_link
{
	my $link = shift;
	my $desc = shift;

	$link =~ s/^\s*//;
	$link =~ s/\s*$//;

	if ($keeplinks{lc $link}) {
		return (defined $desc) ? "[[$link|$desc]]" : "[[$link]]";
	}
	else {
		return (defined $desc) ? $desc : $link;
	}
}

sub process_text
{
	my $title = shift;
  my $text = shift;
  my $link_page_id = shift;

	my $es_site_id = $sites->{ES}{id};

	my $isimage = ($title =~ /^Image:/i) ? 1 : 0;

	if ($isimage) {
		# Unlink Wiki-links
		$text =~ s/\[\[[^\]:]*?\|(.*?)\]\]/\1/g;
		$text =~ s/\[\[([^\]:]*?)\]\]/\1/g;

		# Comment-out Categories
		$text =~ s/(\[\[Category:[^\]]*\]\])/<!-- \1 -->/gi;

		# Add Wikipedia-Attrib-Image template if it doesn't already exist
		my $image = $title;
		$image =~ s/^Image://i;
		$text .= "\n{{Wikipedia-Attrib-Image|$image}}" unless $text =~ /\{\{Wikipedia-Attrib-Image/i;
	}
	else {
		# Processing Wikipedia Extract ...

		# Unlink Wiki-links
		$text =~ s/\[\[([^\]:]*?)\|(.*?)\]\]/&process_link($1,$2)/ge;
		$text =~ s/\[\[([^\]\|:]*?)\]\]/&process_link($1)/ge;

		# Add Wikipedia-Attrib template for comparison purposes.
		$text = "{{Wikipedia-Attrib|$title}}\n" . $text;

		# Remove Portal and Commons templates
		$text =~ s/\{\{portal[^\}]*\}\}//gi;
		$text =~ s/\{\{commons[^\}]*\}\}//gi;

		# Fix Infobox_Software templates
		$text =~ s/\{\{Infobox\sSoftware/{{Infobox_Software/gi;

		# Fix Stub templates
		$text =~ s/\{\{[^\}]*stub\}\}/{{stub}}/gi;

		if (defined $link_page_id) {
			print "\tGetting Encoresoup Categories (page_id = $link_page_id)\n";
			my $catsref = $dbh->selectall_arrayref(
			 "select name
				from categories
				where page_id = $link_page_id
				and site_id = $es_site_id"
			);

			my @cats = map { '[[Category:' . $_->[0] . ']]' } @$catsref;
			my $catstr = join("\n", @cats);
				
			# Replace Categories with marker
			$text =~ s/\[\[Category:[^\]]*\]\]/\%marker\%/gi;

			# Replace first Marker with Encoresoup Categories
			$text =~ s/\%marker\%/$catstr/;
		
			# Remove other markers
			$text =~ s/\%marker\%//g;
		}

		# Comment out language links
		$text =~ s/\[\[([a-z][a-z]|ast|simple):([^\]]*)\]\]/<!--[[$1:$2]]-->/gi;

		# Remove templates not used on Encoresoup
		$text =~ s/\{\{notability[^\}]*\}\}//gi;
		$text =~ s/\{\{primarysources[^\}]*\}\}//gi;
		$text =~ s/\{\{cleanup[^\}]*\}\}//gi;
		$text =~ s/\{\{unreferenced[^\}]*\}\}//gi;
		$text =~ s/\{\{nofootnotes[^\}]*\}\}//gi;
		$text =~ s/\{\{wikify[^\}]*\}\}//gi;
		$text =~ s/\{\{prose[^\}]*\}\}//gi;
		$text =~ s/\{\{orphan[^\}]*\}\}//gi;
		$text =~ s/\{\{this[^\}]*\}\}//gi;
		$text =~ s/\{\{advert[^\}]*\}\}//gi;
		$text =~ s/\{\{fact[^\}]*\}\}//gi;
		$text =~ s/\{\{refimprove[^\}]*\}\}//gi;
		$text =~ s/\{\{weasel[^\}]*\}\}//gi;
		$text =~ s/\{\{for[^\}]*\}\}//gi;
		$text =~ s/\{\{expand[^\}]*\}\}//gi;
		$text =~ s/<!-- Release version update\? Don't edit this page, just click on the version number! -->//gi;

		# Move infobox to start of text
		#my ($prefix) = $text =~ /^(.*)\{\{\s*infobox/ism;
		#return $text unless defined $prefix;
		#my $ib = extract_bracketed($text, '{}', quotemeta $prefix);
		#$text = $ib . $text;
	}

	return $text;
}

sub get_page
{
	my $site = shift;
	my $page = shift;
	my $meta = shift;

	my $url = "http://" . $sites->{$site}{url} . "/api.php";

	$page = uri_unescape($page);
	$page = uri_escape($page);

	my $q = "action=query&prop=revisions&titles=$page&rvlimit=1&rvprop=ids|timestamp&redirects=1&format=xml";
	my $xml =  do_query($url, $q);
	my $text = parse_export_xml($xml, $meta);

	# Check to see if the page already exists, if it does has it been updated?
	my ($page_id, $last_revid) = page_in_cache($site, $meta->{realpage});

	if (defined $meta && defined $page_id) {
		$meta->{existing_page_id} = $page_id;
		$meta->{last_revid} = $last_revid;
	}

	# Indicate where page already in datacache and has not been updated.
	if (defined $meta && exists $meta->{existing_page_id} && ($meta->{last_revid} == $meta->{revid})) {
		$meta->{uptodate} = 1;
		return undef;
	}

	# Page does not exist or is out of date, so go get the text
	print "\tPage out-of-date ... retrieving content\n" if defined $meta && exists $meta->{existing_page_id};
	my $q = "action=query&prop=revisions&titles=$page&rvlimit=1&rvprop=ids|timestamp|content&redirects=1&format=xml";
	my $xml =  do_query($url, $q);
	my $text = parse_export_xml($xml, $meta);
	return $text;
}

sub do_query
{
	my $url = shift;
	my $q = shift;

	my $req = HTTP::Request->new(POST => $url);
	$req->content_type('application/x-www-form-urlencoded');
	$req->content($q);

	my $res = $ua->request($req);

	# Check the outcome of the response
	if ($res->is_success) {
		my $xml = $res->content;
		$xml =~ s/^\s*//;
		return $xml;
	}
	else {
		 print STDERR $res->status_line, "\n";
		 return undef;
	}
}

sub get_infobox_fields
{
	my $text = shift;

	undef %tmplflds;

	my ($prefix) = $text =~ /^(.*)\{\{\s*infobox/ism;
	return unless defined $prefix;
	my $ib = extract_bracketed($text, '{}', quotemeta $prefix);

	get_template_fields($ib);

	return($text, $ib);
}

sub get_template_fields
{
	my $text = shift;

	$text =~ s/^\{\{\s*(.*)\}\}\s*$/\1/ism;

	# Remove HTML Comments
  1 while $text =~ s/(.*)<!--.*?-->(.*)/\1\2/g;
  # Remove <ref> sections
  1 while $text =~ s/(.*)<ref.*?<\/ref>(.*)/\1\2/gi;
  # Temporarily change delimiters inside wikilinks and templates
  1 while $text =~ s/\[\[([^\]]*?)\|([^\]]*?)\]\]/\[\[\1¦\2\]\]/g;
  1 while $text =~ s/\{\{([^\}]*?)\|([^\}]*?)\}\}/\{\{\1¦\2\}\}/g;

	my @tmplflds = split(/\|/, $text);

	undef %tmplflds;

	my $tname = shift @tmplflds;
	$tname =~ s/^\s*//;
	$tname =~ s/\s*$//;

	$tmplflds{template} = $tname;
	#print "Name: $tname\n\n";

	for my $tmplfld (@tmplflds) {
    # Put back wikilink delimiter
    $tmplfld =~ s/¦/|/g;

		my ($key, $val) = split(/=/, $tmplfld, 2);
		map { s/^\s*//; s/\s*$//; } ($key, $val);
		$key =~ s/\s/_/g;

		$tmplflds{$key} = $val;
		
		#print "Key: '$key'\nVal: '$val'\n\n";
	}

	return \%tmplflds;
}

sub create_release_template
{
	my $site = shift;
	my $title = shift;
	my $type = shift;
	my $version = shift;
	my $date = shift;
	my $page_id = shift;

	# Remove download wikilink
	$version =~ s/\[http:[^\s]*\s([^\]]*)\]/\1/;

	# Delink wikilinks
	$date =~ s/\[\[([^\]]*)\]\]/\1/g;
	$date =~ s/release date and age/release_date/;
	$date =~ s/release date/release_date/;
	$date =~ s/release_date\|(mf|df)=(.*?)\|/release_date\|/;
	$date = '{{release_date|' . UnixDate($date,"%Y|%m|%d") . '}}'
			unless $date =~/^\{\{release/;

	my $release_page = "Template:$type/$title";

	my $text = <<EOF
<!-- Please note: This template is auto-generated, so don't change anything except the version and date! -->
{{Release|
 article = $title
|release_type=$type
|release_version = $version
|release_date = $date
}}
<noinclude>
Back to article "'''[[$title]]'''"
</noinclude>
EOF
;

	return $text;
}

sub create_redirect_text
{
	my $page = shift;
	my $site = shift;
	my $redir = shift;

	$page = $dbh->quote($page);
	$redir = $dbh->quote($redir);

	$dbh->do(
	 "insert or replace into redirects
		(
		  page_id,
			site_id,
			title
		)
		select
			a.id,
			a.site_id,
			$redir
		from pages a
		  inner join sites b
			  on a.site_id = b.id
		where a.title = $page
		and b.name = '$site'"
	) || die "While executing:\n" . $dbh->{Statement};
}

sub get_image
{
	my $page = shift;

	my $wppath;
	my $espath;

	# Remove Image: and File: prefixes
	$page =~ s/^Image://i;
	$page =~ s/^File://i;

	# Normalise image name
	$page =~ s/\s/_/g;
	my ($initial, $rest) = $page =~ /^(.)(.*)$/;
	$page = uc($initial) . $rest;

	# Create image subdirectory if necessary
	mkdir "images" unless -d "images";

	# Calculate where Wikipedia will be storing the image.
	my $md5 = MD5->hexhash($page);
	my ($prefix1) = $md5 =~ /^(.)/;
	my ($prefix2) = $md5 =~ /^(..)/;

	$wppath = "$prefix1/$prefix2/$page";

	if ($opts{imagehash}) {
		# Create image hash directories if necessary
		mkdir "images/$prefix1" unless -d "images/$prefix1";
		mkdir "images/$prefix1/$prefix2" unless -d "images/$prefix1/$prefix2";

		$espath = "images/$wppath";
	}
	else {
		$espath = "images/$page";
	}

	my $url = "http://upload.wikimedia.org/wikipedia/en/$wppath";
	my $req = HTTP::Request->new(GET => $url);

	print "Retrieving Image File: $url to '$espath'\n";
	my $res = $ua->request($req, "$espath");

	if (!$res->is_success) {
		print "FAILED: Retrieving Image File: $url\n";
		print $res->status_line, "\n";
	}
	else {
		print "SUCCESS: $url => '$espath'\n\n";
		return 'WP';
	}

	print "Trying Wikimedia Commons ...\n";

	$url = "http://upload.wikimedia.org/wikipedia/commons/$wppath";
	$req = HTTP::Request->new(GET => $url);

	print "Retrieving Image File: $url to '$espath'\n";
	$res = $ua->request($req, "$espath");

	if (!$res->is_success) {
		print "FAILED: Retrieving Image File: $url\n";
		print $res->status_line, "\n\n";
	}
	else {
		print "SUCCESS: $url => '$espath'\n\n";
		return 'CO';
	}

	return 'F';
}

sub get_redirects
{
	my $page = shift;
	my $site = shift;
	my $verbose = shift;

	my @redirects;

	$page = uri_unescape($page);
	$page = uri_escape($page);

	# Get all redirects for page.
	my $wpapi = "http://en.wikipedia.org/w/api.php";
	my $esapi = "http://encoresoup.net/api.php";

	my $url = ($site eq 'WP') ? $wpapi : $esapi;
	my $q = "action=query&list=backlinks&bltitle=$page&bllimit=max&blfilterredir=redirects&format=xml";
	my $xml = do_query($url, $q);

	my ($cont, @redirs);
	do {
		($cont, @redirs) = parse_redir_xml($xml, $verbose);
		map { chomp;  s/^\s*//; s/\s*$//; push @redirects, $_ } @redirs;

		$xml = do_query($wpapi, $q . '&blcontinue=' . $cont) if $cont;
	} while ($cont);

	return @redirects;
}

sub parse_redir_xml
{
	my $xml = shift;
	my $verbose = shift;

	my $cont = "";
	my @titles;

	my $twig = XML::Twig->new(
	 	twig_handlers =>
			{ 'backlinks/bl' => sub
					{ 
						push @titles, $_->att('title');
						print "\t\tFound Redirect: " . $_->att('title') . "\n" if $verbose;
					},
			  'query-continue/backlinks' => sub
					{ 
						$cont = $_->att('blcontinue');
					}
			},
		pretty_print => 'indented'
	);
	eval { $twig->parse($xml); };

	return ($cont, @titles);
}

sub allpages
{
	# Get all page titles. 
	#my $esapi =  "http://encoresoup.net/api.php";
	#my $q = "action=query&list=allpages&aplimit=max&apfilterredir=nonredirects&format=xml";
	#my $xml = do_query($esapi, $q);

	my @allpages;

	$esobj->list( { action => 'query',
									list => 'allpages',
									aplimit => 'max',
									apfilterredir => 'nonredirects'
								}, { hook => sub { my $ref = shift; map { chomp;  s/^\s*//; s/\s*$//; push @allpages, $_ } @$ref; } }
							);

	#my ($cont, @redirs);
#	do {
#		($cont, @pages) = parse_allpages_xml($xml);
#		map { chomp;  s/^\s*//; s/\s*$//; push @allpages, $_ } @pages;

#		$xml = do_query($esapi, $q . '&apfrom=' . $cont) if $cont;
#	} while ($cont);

	print scalar @allpages . " Page Titles\n";
	return @allpages;
}

sub parse_allpages_xml
{
	my $xml = shift;

	my $cont = "";
	my @titles;

	my $twig = XML::Twig->new(
	 	twig_handlers =>
			{ 'allpages/p' => sub
					{ 
						push @titles, $_->att('title');
					},
			  'query-continue/allpages' => sub
					{ 
						$cont = $_->att('apfrom');
					}
			},
		pretty_print => 'indented'
	);
	$twig->parse($xml);

	return ($cont, @titles);
}

sub page_in_cache
{
	my $site = shift;
	my $title = shift;

	my $site_id = $sites->{$site}{id};

	my $page_id = 0;
	my $last_revid = 0;
	($page_id, $last_revid) = $dbh->selectrow_array(
	 "select page_id, revid
		from pages a
		  inner join revisions b
			  on a.id = b.page_id
		where a.title = ?
		and a.site_id = $site_id
		and b.action = 'ORIG'",

		undef,
		$title
	);

	# If not found - check to see if title refers to a redirect
	# (if it does it's the real page we want to use)
	if (!$page_id) {
		($page_id, $last_revid) = $dbh->selectrow_array(
		 "select b.page_id, b.revid
			from pages a
				inner join revisions b
					on a.id = b.page_id
				inner join redirects c
					on a.id = c.page_id
			where c.title = ?
			and a.site_id = $site_id
			and b.action = 'ORIG'",

			undef,
			$title
		);
	}

	return ($page_id, $last_revid);
}

sub delete_page_id
{
	my $page_id = shift;

	$dbh->do("delete from pages where id = $page_id");
	$dbh->do("delete from revisions where page_id = $page_id");
	$dbh->do("delete from text where page_id = $page_id");
	$dbh->do("delete from templates where page_id = $page_id");
	$dbh->do("delete from tmplflds where page_id = $page_id");
	$dbh->do("delete from categories where page_id = $page_id");
	$dbh->do("delete from pagelinks where page_id_parent = $page_id");
	$dbh->do("delete from pagelinks where page_id_child = $page_id");
	$dbh->do("delete from redirects where page_id = $page_id");
}

sub store_page
{
	my $dbh = shift;
	my $site = shift;
	my $title = shift;
	my $text = shift;
	my $tmplflds = shift;
	my $parent_page_id = shift;
	my $parent_page = shift;
	my $meta = shift;

	my $revision_id;
	my $text_id;
	my $template_id;

	my $site_id = $sites->{$site}{id};
	die "Unknown site: '$site'\n" if !defined $site_id;

	# If page already in datacache and has not been updated, then just return.
	if (defined $meta && exists $meta->{uptodate}) {
		print "\tPage '$title' is already up to date!\n";
		return 0;
	}

	# If newer version exists, delete the old details
	if ($meta->{existing_page_id}) {
		print "\tNewer version of '$title' exists, deleting existing details from cache\n";
		delete_page_id($meta->{existing_page_id});
	}

	$dbh->do(
	 "insert into pages
	 	(
			site_id,
			title,
			updated
		)
		values
		(
			$site_id,
			?,
			1
		)",

		undef,
		$title,
	);

	my $page_id = $dbh->last_insert_id(undef, undef, undef, undef);

	my $revision_id = store_revision($dbh, $site_id, $page_id, 'ORIG', $text, $meta);

	if (defined $tmplflds) {
		my $tname = $tmplflds->{template};
		$dbh->do(
		 "insert into templates
			(
				page_id,
				site_id,
				name
			)
			values
			(
				$page_id,
				$site_id,
				'$tname'
			)"
		);

		my $template_id = $dbh->last_insert_id(undef, undef, undef, undef);

		while (my ($key,$val) = each %$tmplflds) {
			$dbh->do(
			 "insert or replace into tmplflds
				(
					template_id,
					page_id,
					site_id,
					field, 
					value
				)
				values
				(
					$template_id,
					$page_id,
					$site_id,
					'$key',
					'$val'
				)"
			);
		}
	}

	my @cats = $text =~ /(\[\[Category:[^\]]*\]\])/ig;
	for my $cat (@cats) {
		$cat =~ s/\[\[Category:([^\]]*)\]\]/\1/i;

		$dbh->do(
		 "insert into categories
			(
				revision_id,
				page_id,
				site_id,
				name
			)
			values
			(
				$revision_id,
				$page_id,
				$site_id,
				'$cat'
			)"
		);
	}

	if (defined $parent_page_id) {
		$dbh->do(
		 "update pages
			set parent_id = $parent_page_id,
					parent_page = (select title from pages where id = $parent_page_id)
			where id = $page_id"
		);
	}

	return $page_id;
}

sub store_revision
{
	my $dbh = shift;
	my $site_id = shift;
	my $page_id = shift;
	my $action = shift;
	my $text = shift;
	my $meta = shift;
	
	my $revid = $meta->{revid} || 0;

	$dbh->do(
	 "insert into revisions
	 	(
			page_id,
			site_id,
			revid,
			revts,
			action,
			updated
		)
		values (
			$page_id,
			$site_id,
			$revid,
			'$meta->{revts}',
			'$action',
			1
		)"
	);

	my $revision_id = $dbh->last_insert_id(undef, undef, undef, undef);

	$dbh->do(
	 "insert into text
		(
			revision_id,
			page_id,
			site_id,
			text
		)
		values
		(
			$revision_id,
			$page_id,
			$site_id,
			?
		)",

		undef,
		$text
	);

	$dbh->do(
	 "update pages
		set latest_action = '$action'
		where id = $page_id"
	);

	return $revision_id;
}

sub export_pages
{
	my $opts = shift;

	my $site = $opts->{site};
	my $page = $opts->{page};
	my $parent = $opts->{parent} || 0;
	my $updated = $opts->{updated} || 0;
	my $level = shift || 0;

	unlink $sites->{$site}{file} if !$parent;

	my $updsql = ($updated) ? "and a.updated = 1" : "";
	my $parsql = ($parent) ?
		"and a.parent_id = $parent" :
		"and b.name = '$site' and a.parent_id is null";

	$parsql .= "\nand a.title = " . $dbh->quote($page) if (!$parent && defined $page);

	# There must be a better way of doing this, but I'm too tired right now!
	my $sth = $dbh->prepare(
	 "select a.id, a.title, d.text
		from pages a
		  inner join sites b
			  on a.site_id = b.id
			inner join revisions c
				on a.id = c.page_id
			inner join text d
			  on c.id = d.revision_id
		where c.action = a.latest_action
		$parsql
		$updsql
		order by a.title"
	);

	$sth->execute();

	my ($page_id, $title, $text);
	while (($page_id, $title, $text) = $sth->fetchrow_array) {
		$text = decode_utf8($text);
		$title = decode_utf8($title);
		print ("\t" x $level . "Exporting $title...\n");

		open FH, ">>:utf8", $sites->{$site}{file};

		print FH "{{-start-}}\n";
		print FH "'''$title'''\n";
		print FH $text, "\n";
		print FH "{{-stop-}}\n";

		close FH;

		$opts->{parent} = $page_id;
		export_pages($opts, $level+1);

		export_redirects($site, $title, $page_id, $level);
	}
}

sub update_pages
{
	my $site = shift;

	my $startcond = "";
	$startcond = "and a.title >= '$opts{start}'" if defined $opts{start};

	my $sth = $dbh->prepare(
	 "select a.title
		from pages a
		  inner join sites b
			  on a.site_id = b.id
		where b.name = '$site'
		and a.parent_id is null
		$startcond
		order by a.title"
	);

	$sth->execute();

	my $title;
	while (($title) = $sth->fetchrow_array) {
		$title = decode_utf8($title);
		process_page($site, $title);
	}
}

sub existing_page_text
{
	my $page_id = shift;

	my ($text) = $dbh->selectrow_array(
	 "select c.text
		from pages a
			inner join revisions b
				on a.id = b.page_id
				and a.latest_action = b.action
			inner join text c
			  on b.id = c.revision_id
		where a.id = $page_id"
	);

	return $text;
}

sub link_matching_page
{
	my $dbh = shift;
	my $site = shift;
	my $page = shift;
	my $page_id = shift;

	my $site_id = $sites->{$site}{id};
	my $es_site_id = $sites->{ES}{id};

	my $link_page_id = 0;

	($link_page_id) = $dbh->selectrow_array(
	 "select id
	  from pages
		where title = '$page'
		and site_id = $es_site_id"
	);

	if (!$link_page_id) {
		# There might be a redirect with the matching title
		($link_page_id) = $dbh->selectrow_array(
		 "select page_id
			from redirects
			where title = '$page'
			and site_id = $es_site_id"
		);
	}

	return unless $link_page_id;

	# First check if there is already a link!
	my ($count) = $dbh->selectrow_array(
	 "select count(*)
	  from pagelinks
		where page_id_parent = $page_id
		and page_id_child = $link_page_id"
	);

	return if $count;

	# Link the pages together
	$dbh->do(
	 "insert into pagelinks
	  (
			site_id_parent,
		  page_id_parent,
			site_id_child,
			page_id_child
		)
		values
		(
			$site_id,
			$page_id,
			$es_site_id,
			$link_page_id
		)"
	);

	return $link_page_id;
}

sub print_status
{
	my $status = $dbh->selectall_arrayref(
	 "select s.name, count(*)
		from pages p
			inner join sites s
				on p.site_id = s.id
		group by s.name"
	);

	for my $site (@$status) {
		print $site->[0], "\t", $site->[1], "\n";
	}
}

sub delete_page
{
	my $site = shift;
	my $title = shift;

	my $site_id;
	my $page_id;

	$site_id = $sites->{$site}{id};
	die "Unknown site: '$site'\n" if !defined $site_id;

	print "DELETING Page: $title\n";
	my $page_id = 0;
	($page_id) = $dbh->selectrow_array(
	 "select id
		from pages
		where title = ?
		and site_id = $site_id",

		undef,
		$title
	);

	if (!$page_id) {
		print "\tNo such page!\n";
		return 0;
	}

	my $sth = $dbh->prepare(
	 "select title
		from pages
		where parent_id = $page_id
		and site_id = $site_id"
	);

	$sth->execute;

	while (my ($title) = $sth->fetchrow_array) {
		delete_page($site, $title);
	}

	delete_page_id($page_id);

	print "\tPage DELETED!\n";
}

sub relink_images
{
	my $site = shift;

	my $site_id = $sites->{$site}{id};

	my $site_id_clause = ($site_id == 1) ? "site_id = 1" : "site_id <> 1";

	my $sth = $dbh->prepare(
	 "select a.id, a.title
		from pages a
		where a.site_id = $site_id
		and a.parent_id is null
		order by a.id"
	);

	$sth->execute();

	my ($page_id, $title);
	while (($page_id, $title) = $sth->fetchrow_array) {
		my $text = existing_page_text($page_id);

		print "Relinking Images in $title\n";

		if ($text) {
			my $nocomments = $text;
			$nocomments =~ s/<!--.*?-->//g;
			my @images = ($nocomments =~ /\[\[(Image:[^\#\|\]]+)/gi);
			map {
				s/[^[:ascii:]]+//g;
				s/<!--.*?-->//g;
				s/Image:(.)/Image:\u\1/i;

				my ($link_id) = $dbh->selectrow_array("select id from pages where title = '$_' and $site_id_clause");
				# If not found, try again replacing spaces in title with underscores
				if (!defined $link_id) {
					s/\s/_/g;
					($link_id) = $dbh->selectrow_array("select id from pages where title = '$_' and $site_id_clause");
				}
				# Still not found, try all underscores to spaces!
				if (!defined $link_id) {
					s/_/ /g;
					($link_id) = $dbh->selectrow_array("select id from pages where title = '$_' and $site_id_clause");
				}
				if (defined $link_id) {
					$dbh->do(
					 "update pages
						set parent_id = $page_id,
								parent_page = '$title'
						where id = $link_id"
					);
					print "\tPage $_ Relinked to Parent Page $page_id\n";
				}
				else {
					print "Page $_ Not Found!\n";
				}
			} @images;
		}
	}
}

sub import_pages
{
	my $site = shift;
	
	my $file = $sites->{$site}{file};

	my $title = "";
	my $text = "";
	my $atstart = 0;

	open FH, "<:utf8", $file;

	while (<FH>) {
		chomp;

		if ($_ eq '{{-start-}}') {
			$atstart = 1;
			next;
		}

		if ($atstart && ($_ =~ /^'''.*'''$/)) {
			($title) = /^'''(.*)'''$/;
			$atstart = 0;
			next;
		}

		if ($_ eq '{{-stop-}}') {
			print "TITLE: $title\n\n";
			#Needs some work
			#store_page($dbh, $site, $title, $text, undef, undef, undef);

			$title = $text = "";
			next;
		}

		$text .= "$_\n";
	}

	close FH;
}

sub export_redirects
{
	my $site = shift;
	my $title = shift;
	my $page_id = shift;
	my $level = shift;

	open FH, ">>:utf8", $sites->{$site}{file};

	my $sth = $dbh->prepare(
	 "select title
		from redirects
		where page_id = $page_id"
	);

	$sth->execute();

	while (my ($redir) = $sth->fetchrow_array) {
		next if $redir =~ /^User:/;

		print ("\t" x ($level+1) . "Exporting Redirect $redir...\n");
		
		print FH "{{-start-}}\n";
		print FH "'''$redir'''\n";
		print FH "#REDIRECT [[$title]]\n";
		print FH "{{-stop-}}\n";
	}

	close FH;
}
