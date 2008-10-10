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
#		--keeplinks	Specifies file containing list of page titles, one per line.
#		            Links pointing to these pages will be not be delinked.
#   --redirects Export redirects pointing to required pages.
#   --rebuild-klcache Rebuild the keeplinks.cache file for given keeplinks file, add redirects if 
#                     --redirects is also specified.
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
#     esplus.txt   Supporting pages -
#                      List of Wikipedia contributors goes in page Template:WPContrib/<page title>
#                      Release version templates where applicable go in page
#                         Template:Latest_stable_release/<page title> and
#                         Template:Latest_preview_release/<page title>
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

binmode STDOUT, ':utf8';
$| = 1;

# Hashref storing site information.
my $sites;

my %tmplflds;
my %meta;

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
	'keeplinks:s',
	'redirects',
	'rebuild-klcache',
	'allpages',
	'export-updated|export',
	'export-all',
	'merge-fixup',
	'status'
) or die("$usage\nInvalid Option\n");

die ("Must specify site!\n") unless defined $opts{site} || defined $opts{status};

map { $opts{$_} = 0 if !exists($opts{$_}) } qw/merge imagehash getimages redirects rebuild-klcache allpages merge-fixup/;

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

if ($opts{status}) {
	print_status();
	exit 0;
}

if ($opts{'export-updated'}) {
	export_pages(uc $opts{site}, 0, 1);
	exit 0;
}

if ($opts{'export-all'}) {
	export_pages(uc $opts{site}, 0, 0);
	exit 0;
}

if ($opts{'merge-fixup'}) {
	create_version_templates();
	exit 0;
}

# Reset 'updated' flags
$dbh->do("update pages set updated = 0");

unlink "wp.txt";
unlink "esplus.txt";
unlink "es.txt" if $opts{merge};

my $siteinfo = $dbh->selectrow_hashref("select * from sites where name = '$opts{site}'");

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
else {
	print STDERR "Either --file, --page or --allpages must be supplied\n\n";
}

my %keeplinks;
if (exists $opts{keeplinks}) {
	my $klfile = ($opts{keeplinks}) ? $opts{keeplinks} : 'keeplinks.cache';
	
	my @keeplinks = map { chomp; s/^\s*//; s/\s*$//; $_ } (read_file($klfile), @pages);
	%keeplinks = map { lc $_ => 1 } (@keeplinks);

	if ($opts{'rebuild-klcache'}) {
		if ($opts{redirects}) {
			print "Getting redirects for keeplinks pages\n";
			my $progress = Term::ProgressBar->new({count => scalar(@keeplinks), ETA => 'linear'});
			for (my $i = 0; $i < @keeplinks; $i++) {
				my $link = $keeplinks[$i];
				my @redirs = get_redirects($link,'WP',0);
				map { $keeplinks {lc $_} = 1 } (@redirs);
				$progress->update();
			}

			open FH, ">:utf8", "keeplinks.cache";
			print FH join("\n", sort keys %keeplinks);
			close FH;
		}
	}
}

# while loop - allows for additional pages to be pushed onto the end of @pages;
while (my $page = shift @pages) {
	process_page($opts{site}, $page);
}

$dbh->disconnect();
exit 0;

sub process_page
{
	my $site = shift;
	my $page = shift;

	my $isimage;
	my $filter;

	undef %tmplflds;

	chomp $page;

	print "Processing Page: $page\n";

	$isimage = ($page =~ /^Image:/i) ? 1 : 0;

	print "\tExporting From " . $siteinfo->{desc} . "\n";
	my $xml = get_page($site, $page);

	# Pass in reference to $realpage, gets correct title if we supplied a redirect.
	my $realpage;
	my $text = parse_export_xml($xml, \$realpage);
	if (!defined $text) {
		# undef returned only for images, where 'missing' attributes is set.
		# - indicates image description is on Wikimedia Commons.
		print "\tExporting From Wikimedia Commons\n";
		$site = 'CO';
		my $xml = get_page($site, $page);
		$text = parse_export_xml($xml, \$realpage);
	}

	# No such page!
	if (!defined $text) {
		print "\tPage Does Not Exist: $page\n";
		return;
	}

	if ($page ne $realpage) {
		print "\tActual Page Title: $realpage\n";
		$page = $realpage;
	}

	my $page_id = store_page($dbh, $site, $page, $text, \%tmplflds);

	# page_id will be zero if page already exists and does not need updating.
	if ($page_id && ($site ne 'ES')) {
		# Try to locate equivalent page on Encoresoup
		my $link_page_id = link_matching_page($dbh, $site, $page, $page_id);

		$text = process_text($page, $text, $page_id, $link_page_id);
		store_revision($dbh, $sites->{$site}{id}, $page_id, 'ESMERGE', $text);
	}

	# Identify Images
	if ($opts{getimages}) {
		my @images = ($text =~ /\[\[(Image:[^\#\|\]]+)/gi);
		map { s/[^[:ascii:]]+//g; push @pages, $_; } @images;
	}

	if (($tmplflds{frequently_updated} =~ /yes/i) || ($site eq 'ES')){
		print "\tNEED TO GET VERSION TEMPLATE!!\n\n";

		undef %tmplflds;
		my $xml = get_page($site, "Template:Latest_stable_release/$page");
		$text = parse_export_xml($xml, \$realpage);
		my $ib = extract_bracketed($text, '{}');
		get_template_fields($ib);
		store_page($dbh, $site, "Template:Latest_stable_release/$page", $text, \%tmplflds, $page_id)
			if defined $text;

		undef %tmplflds;
		$xml = get_page($site, "Template:Latest_preview_release/$page");
		$text = parse_export_xml($xml, \$realpage);
		$ib = extract_bracketed($text, '{}');
		get_template_fields($ib);
		store_page($dbh, $site, "Template:Latest_preview_release/$page", $text, \%tmplflds, $page_id)
			if defined $text;
	}

	# If we are getting a Image: page, then go get the corresponding image file
	my $image_src;
	$image_src = get_image($page) if ($isimage);

	# Do Wikipedia Revision Info Export
	get_contributors($site, $page, $page_id);

	# Add redirects
	if ($opts{redirects}) {
		print "\tCreating Redirect Pages\n";
		my @redirs = get_redirects($page,$site,1);
		map { create_redirect_text($page, $site, $_) } @redirs;
	}
}

sub create_version_templates
{
	my ($title, $site, $latest_preview_date, $latest_preview_version);

	my $sth = $dbh->prepare(
	 "select d.title, e.name, b.value, c.value
		from templates a
		  inner join tmplflds b
			  on a.id = b.template_id
		  inner join tmplflds c
				on a.id = c.template_id
		  inner join pages d
		    on d.id = a.page_id
			inner join sites e
				on e.id = d.site_id
		where a.name in ('Infobox Software','Infobox_Software')
		and b.field = 'latest_preview_date'
		and c.field = 'latest_preview_version'
		and not exists
		(
			select 1
			from pages f
			where f.title = 'Template:Latest_preview_release/' || d.title
			and f.site_id = d.site_id
		)"
	);

	$sth->execute;

	my @row;
	while (@row = $sth->fetchrow_array) {
		my ($title, $site, $latest_preview_date, $latest_preview_version) = @row;
		
		my %tmplflds = (
			article => $title,
			release_type => 'Latest_preview_release',
			release_version => $latest_preview_version,
			release_date => $latest_preview_date
		);

		my $text = <<EOF
{{-start-}}\n'''$title'''
<!-- Please note: This template is auto-generated, so don't change anything except the version and date! -->
{{Release
|article = $title
|release_type=Latest_preview_release
|release_version = $latest_preview_version
|release_date = $latest_preview_date
}}
<noinclude>
Back to article "'''[[$title]]'''"
</noinclude>
{{-stop-}}
EOF
;
		my $page = "Template:Latest_preview_release/$title";
		print "\tCreating Page: $page\n";
		$meta{revid} = 0;
		$meta{revts} = '';
		store_page($dbh, $site, $page, $text, \%tmplflds);
	}
}

sub get_contributors
{
	my $site = shift;
	my $page = shift;
	my $page_id = shift;

	my $contrib_page = $page;
	$contrib_page =~ s/:/_/g;
	$contrib_page = "Template:WPContrib/$contrib_page";

	my $text;

	print "\tExporting Contributors from " . $sites->{$site}{desc} . "...\n";

	if ($site eq 'ES') {
		my $xml = get_page($site, $contrib_page);
		$text = parse_export_xml($xml);
	}
	else {
		my %contribs;

		# Get details from Wikimedia commons if we just got an image from there.
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

	store_page($dbh, $site, $contrib_page, $text, undef, $page_id);
}

sub parse_export_xml
{
	my $xml = shift;
	my $realpage = shift; # Must be a reference;

	my $title = "";
	my $text = "";
	my $revid = 0;
	my $revts = "";
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
						# If missing attribute set, then discard this page and return undef.
						if (exists $_->atts->{missing}) {
							$missing = 1;
							return;
						}
					
						$title = $_->att('title');
					}
			},
		pretty_print => 'indented'
	);
	$twig->parse($xml);

	return undef if $missing;

	$$realpage = $title if defined $realpage && ref $realpage;

	$meta{revid} = $revid;
	$meta{revts} = $revts;

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
		$text = "{{Wikipedia-Attrib|$title}}" . $text;

		# Remove Portal and Commons templates
		$text =~ s/\{\{portal[^\}]*\}\}//gi;
		$text =~ s/\{\{commons[^\}]*\}\}//gi;

		# Fix Infobox_Software templates
		$text =~ s/\{\{Infobox\sSoftware/{{Infobox_Software/gi;

		# Fix Stub templates
		$text =~ s/\{\{[^\}]*stub\}\}/{{stub}}/gi;

		my $catsref = $dbh->selectall_arrayref(
		 "select name
			from categories
			where page_id = $link_page_id"
		);

		my @cats = map { '[Category:' . $_->[0] . ']' } @$catsref;
		my $catstr = join("\n", @cats);
				
		# Replace Categories with marker
		$text =~ s/\[\[Category:[^\]]*\]\]/\%marker\%/gi;

		# Replace first Marker with Encoresoup Categories
		$text =~ s/\%marker\%/$catstr/;
		
		# Remove other markers
		$text =~ s/\%marker\%//g;

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

		get_infobox_fields($text);
	}

	return $text;
}

sub get_page
{
	my $site = shift;
	my $page = shift;

	my $url = "http://" . $sites->{$site}{url} . "/api.php";

	my $q = "action=query&prop=revisions&titles=$page&rvlimit=1&rvprop=content|ids|timestamp&redirects=1&format=xml";
	return do_query($url, $q);
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
	return unless $prefix;
	my $ib = extract_bracketed($text, '{}', quotemeta $prefix);

	get_template_fields($ib);
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

		my ($key, $val) = split(/=/, $tmplfld);
		map { s/^\s*//; s/\s*$//; } ($key, $val);
		$key =~ s/\s/_/g;

		$tmplflds{$key} = $val;
		
		#print "Key: '$key'\nVal: '$val'\n\n";
	}
}

sub create_release_template
{
	my $title = shift;
	my $type = shift;
	my $version = shift;
	my $date = shift;

	my $file = 'esplus.txt';

	# Remove download wikilink
	$version =~ s/\[http:[^\s]*\s([^\]]*)\]/\1/;

	# Delink wikilinks
	$date =~ s/\[\[([^\]]*)\]\]/\1/g;
	$date =~ s/release date and age/release_date/;
	$date =~ s/release date/release_date/;
	$date = '{{release_date|' . UnixDate($date,"%Y|%m|%d") . '}}'
			unless $date =~/^\{\{release/;
	
	open FH, ">>:utf8", $file;

	print FH <<EOF
{{-start-}}
'''Template:$type/$title'''
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
{{-stop-}}
EOF
;

	close FH
}

sub create_redirect_text
{
	my $page = shift;
	my $site = shift;
	my $redir = shift;

	#print FH <<EOF
#{{-start-}}
#'''$redir'''
#REDIRECT [[$page]]
#{{-stop-}}
#EOF
#;

	$dbh->do(
	 "insert into redirects
		(
		  page_id,
			site_id,
			title
		)
		select
			id,
			site_id,
			'$redir'
		from pages
		where title = '$page'"
	);
}

sub get_image
{
	my $page = shift;

	my $wppath;
	my $espath;

	# Remove Image: prefix
	$page =~ s/^Image://i;

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
	$twig->parse($xml);

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

sub store_page
{
	my $dbh = shift;
	my $site = shift;
	my $title = shift;
	my $text = shift;
	my $tmplflds = shift;
	my $parent_page = shift;

	my $site_id;
	my $page_id;
	my $revision_id;
	my $text_id;
	my $template_id;

	$site_id = $sites->{$site}{id};
	die "Unknown site: '$site'\n" if !defined $site_id;

	# Check to see if the page already exists, if it does has it been updated?
	my $page_id = 0;
	my $last_revid = 0;
	($page_id, $last_revid) = $dbh->selectrow_array(
	 "select page_id, revid
		from pages a
		  inner join revisions b
			  on a.id = b.page_id
		where a.title = ?
		and a.site_id = $site_id
		and b.action = 'ORIG'"
	);

	# If page already in datacache and has not been updated, then just return.
	return 0 if defined $last_revid && ($last_revid == $meta{revid});

	# If newer version exists, delete the old details
	if ($page_id) {
		$dbh->do("delete from pages where page_id = $page_id");
		$dbh->do("delete from revisions where page_id = $page_id");
		$dbh->do("delete from text where page_id = $page_id");
		$dbh->do("delete from templates where page_id = $page_id");
		$dbh->do("delete from tmplflds where page_id = $page_id");
		$dbh->do("delete from categories where page_id = $page_id");
		$dbh->do("delete from pagelinks where page_id_parent = $page_id");
		$dbh->do("delete from pagelinks where page_id_child = $page_id");
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

	$page_id = $dbh->last_insert_id(undef, undef, undef, undef);

	my $revision_id = store_revision($dbh, $site_id, $page_id, 'ORIG', $text);

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

	if (defined $parent_page) {
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
				$parent_page,
				$site_id,
				$page_id
			)"
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
			$meta{revid},
			'$meta{revts}',
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
	my $site = shift;
	my $parent = shift;
	my $updated = shift;
	my $level = shift || 0;

	unlink $sites->{$site}{file} if !$parent;

	my $updsql = ($updated) ? "and a.updated = 1" : "";
	my $parsql = ($parent) ?  "and l.page_id_parent = $parent" : "and l.page_id_parent is null";

	my $sth = $dbh->prepare(
	 "select a.id, a.title, d.text
		from pages a
		  inner join sites b
			  on a.site_id = b.id
			inner join revisions c
				on a.id = c.page_id
			inner join text d
			  on c.id = d.revision_id
			left join pagelinks l
				on a.id = l.page_id_child
				and a.site_id = l.site_id_child
				and a.site_id = l.site_id_parent
		where b.name = '$site'
		and c.action = a.latest_action
		$parsql
		$updsql
		order by title"
	);

	$sth->execute();

	open FH, ">>:utf8", $sites->{$site}{file};

	my ($page_id, $title, $text);
	while (($page_id, $title, $text) = $sth->fetchrow_array) {
		print ("\t" x $level . "Exporting $title...\n");

		print FH "{{-start-}}\n";
		print FH "'''$title'''\n";
		print FH $text, "\n";
		print FH "{{-stop-}}\n";

		export_pages($site, $page_id, $updated, $level+1);
	}

	close FH;
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

	# First check if there is already a link!
	($link_page_id) = $dbh->selectrow_array(
	 "select page_id_parent
	  from pagelinks
		where site_id_parent = $site_id
		and page_id_parent = $page_id
		and site_id_child = $es_site_id"
	);

	return if $link_page_id;

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

	# Link the pages together
	$dbh->do(
	 "insert into pagelinks
	  (
			site_id_parent,
		  page_id_parent,
			site_id_child,
			page_id_child
		)
		select 
			$site_id,
			$page_id,
			$es_site_id,
			$link_page_id"
	);
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

