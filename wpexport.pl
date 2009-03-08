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

my $script=basename($0);
my $usage="Usage: $script [--<opts>]";

my %opts;
Getopt::Long::Configure("bundling");
GetOptions (\%opts,
	'db=s',
	'site=s',
  'merge=s',
	'imagehash',
	'getimages',
  'file=s',
  'page=s',
	'pageid=i',
	'allpages',
	'export-updated|export',
	'export-all',
	'status',
	'delete',
	'update',
	'relink-images',
	'nocontrib',
	'import',
	'start=s',
	'rescan'
) or die("$usage\nInvalid Option\n");

die ("Must specify site!\n") unless defined $opts{site} || defined $opts{status} || defined $opts{merge};

map { $opts{$_} = 0 if !exists($opts{$_}) } qw/imagehash getimages allpages delete status update relink-images nocontrib import rescan/;

# Create a user agent object
my $ua = LWP::UserAgent->new;
$ua->agent("WPExport/0.1 ");
$ua->default_header(
	'Accept-Language' => 'en-US',
	'Accept-Charset' => 'utf-8'
);

# Create MediaWiki::API objects
my $esobj = MediaWiki::API->new( { api_url => 'http://encoresoup.net/api.php' } );

my $dbname = $opts{db} || 'wpexport.db';

# Connect to local SQLite datacache
my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");

# Cache 'sites' table into hashref
$sites = $dbh->selectall_hashref("select * from sites", 'name');

# Load extension modules
my @modulenames;
my @modules;
if (-f "modules/modules.conf") {
	@modulenames = map { chomp;  s/^\s*//; s/\s*$//; $_ } read_file("modules/modules.conf");

	for my $modulename (@modulenames) {
		next if !$modulename || $modulename =~ /^#/;
		require "modules/$modulename.pm";
		push @modules, $modulename->new($dbh);
	}
}

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

if ($opts{'merge'}) {
	merge_changes($opts{merge});
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
elsif (!$opts{'export-updated'} && !$opts{'export-all'} && !$opts{merge}) {
	print STDERR "Either --file, --page or --allpages must be supplied\n\n";
}

if ($opts{delete}) {
	if ($opts{pageid}) {
		delete_page_id($opts{pageid});
		exit 0;
	}

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
my $first = 1;
while (my $page = shift @pages) {
	if ($opts{'export-updated'}) {
		export_pages({site => uc $opts{site}, page => $page, updated => 1, append => (($first) ? 0 : 1)});
	}
	elsif ($opts{'export-all'}) {
		export_pages({site => uc $opts{site}, page => $page, updated => 0, append => (($first) ? 0 : 1)});
	}
	else {
		# Reset 'updated' flags
		$dbh->do("update pages set updated = 0");

		process_page($opts{site}, $page);
	}

	$first = 0;
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
	my %meta;

	undef %tmplflds;

	chomp $page;

	print "Processing Page: $page\n";

	my $isimage = ($page =~ /^(?:Image|File):/i) ? 1 : 0;

	print "\tExporting From " . $siteinfo->{desc} . "\n";
	my $text = get_page($site, $page, \%meta);

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

	my $page_id = store_page($dbh, $site, $page, $text, \%tmplflds, $parent_page_id, $parent_page, \%meta);

	# page_id will be zero if page already exists and does not need updating.
	if ($page_id && ($site ne 'ES')) {
		for my $module (@modules) {
			$text = $module->process_text($dbh, $page, $site, $text, $page_id);
		}

		store_revision($dbh, $sites->{$site}{id}, $page_id, 'ESMERGE', $text, \%meta);

		# Do Wikipedia Revision Info Export
		get_contributors($site, $page, $page_id) unless $opts{nocontrib};
	}
	else {
		# Get the existing page for child pages to link to.
		$page_id = $meta{existing_page_id};
		$text = existing_page_text($page_id);
	}

	get_template($text, 1) if defined $text;

	if (($tmplflds{frequently_updated} =~ /yes/i) || ($site eq 'ES')){
		my $text; # Shield outer $text;

		print "\tNEED TO GET VERSION TEMPLATE!!\n\n" unless $site eq 'ES';

		for my $tmpl ('Latest stable release','Latest preview release') {
			undef %tmplflds;
			undef %meta;
			my $tmpl_page = $meta{cachedpage} = "Template:$tmpl/$page";
			my $text = get_page($site, "$tmpl_page", \%meta);
			if (!exists $meta{missing} && !exists $meta{uptodate}) {
				get_template($text,0);

				my $tmpl_page_id = store_page($dbh, $site, $tmpl_page, $text, \%tmplflds, $page_id, $page, \%meta);

				if ($tmplflds{template} ne 'Release') {
					my $latest_release_version = $tmplflds{latest_release_version};
					my $latest_release_date = $tmplflds{latest_release_date};

					my $text = create_release_template($site, $page, $tmpl, $latest_release_version, $latest_release_date, $page_id);
					store_revision($dbh, $sites->{$site}{id}, $tmpl_page_id, 'ESMERGE', $text, \%meta);
				}
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
				my $text = create_release_template($site, $page, 'Latest stable release', $latest_release_version, $latest_release_date, $page_id);
				my ($tmpl_page_id, $last_revid) = page_in_cache($site, "Template:Latest stable release/$page");
				store_page($dbh, $site, "Template:Latest stable release/$page", $text, undef, $page_id, $page, { existing_page_id => $tmpl_page_id });
			}
			if ($latest_preview_version) {
				my $text = create_release_template($site, $page, 'Latest preview release', $latest_preview_version, $latest_preview_date, $page_id);
				my ($tmpl_page_id, $last_revid) = page_in_cache($site, "Template:Latest preview release/$page");
				store_page($dbh, $site, "Template:Latest preview release/$page", $text, undef, $page_id, $page, { existing_page_id => $tmpl_page_id });
			}
		}
	}

	store_properties($dbh, $sites->{$site}{id}, $page_id, \%tmplflds);

	# Identify Images
	if ($text && $opts{getimages}) {
		my $nocomments = $text;
		$nocomments =~ s/<!--.*?-->//g;
		my @images = ($nocomments =~ /\[\[((?:Image|File):[^\#\|\]]+)/gi);
		map { s/[^[:ascii:]]+//g; s/<!--.*?-->//g; process_page($site, $_, $page_id, $page); } @images;
	}

	# If we are getting a Image: page, then go get the corresponding image file
	get_image($page) if ($isimage && $page_id && !exists $meta{missing} && ($site ne 'ES'));

	# Add redirects
	print "\tCreating Redirect Pages\n";
	my @redirs = get_redirects($page,$site,1);
	push @redirs, $orig_page_name if defined $orig_page_name;
	map { create_redirect_text($page, $site, $_) } @redirs;
}

sub rescan_page
{
	my $site = shift;
	my $page = shift;
	my $parent_page_id = shift;
	my $parent_page = shift;

	my $isimage;
	my $filter;
	my $orig_page_name;
	my %meta;

	undef %tmplflds;

	chomp $page;

	print "Rescanning Page: $page\n";

	my $isimage = ($page =~ /^(?:Image|File):/i) ? 1 : 0;

	my ($text, $page_id) = $dbh->selectrow_array(
	 "select c.text, a.id
		from pages a
			inner join revisions b
				on a.id = b.page_id
				and b.action = 'ORIG'
			inner join text c
				on b.id = c.revision_id
			inner join sites d
				on a.site_id = d.id
		where a.title = ?
		and d.name = '$site'",

		undef,
		$page
	);

	# No such page!
	if (!defined $text) {
		print "\tPage Does Not Exist: $page\n";
		return;
	}

	$text = decode_utf8($text);

	if ($site ne 'ES') {
		for my $module (@modules) {
			$text = $module->process_text($dbh, $page, $site, $text, $page_id);
		}

		store_revision($dbh, $sites->{$site}{id}, $page_id, 'ESMERGE', $text, \%meta);
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
		$linkpage = ':' . $page if $page =~ /^(?:Image|File):/i;

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

	my %pages;

	delete $meta->{missing} if defined $meta;
	my $twig = XML::Twig->new(
	 	twig_handlers =>
			{ 
			  'revisions/rev' => sub
					{
						$text = decode_utf8($_->text);
						$revid = $_->atts->{revid};
						$revts = $_->atts->{timestamp};
					},
				'page' => sub
					{ 
						$title = decode_utf8($_->att('title'));

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

sub get_page
{
	my $site = shift;
	my $page = shift;
	my $meta = shift;

	my $url = "http://" . $sites->{$site}{url} . "/api.php";
	my $alturl = "http://" . $sites->{$site}{alt_url} . "/api.php";

	$page = uri_unescape($page);
	$page = uri_escape_utf8($page);

	my $q = "action=query&prop=revisions&titles=$page&rvlimit=1&rvprop=ids|timestamp&redirects=1&format=xml";
	my $xml =  do_query($url, $q);
	my $text = parse_export_xml($xml, $meta);

	if (defined $meta && (exists $meta->{missing}) && (defined $sites->{$site}{alt_url})) {
		$url = $alturl;
		$page = $meta->{realpage} if exists $meta->{realpage};
		$page = uri_escape_utf8($page);
		$q = "action=query&prop=revisions&titles=$page&rvlimit=1&rvprop=ids|timestamp&redirects=1&format=xml";
		$xml = do_query($url, $q);
		$text = parse_export_xml($xml, $meta);
	}

	my $cachedpage = (exists $meta->{cachedpage}) ? $meta->{cachedpage} : $meta->{realpage};

	# We don't support File: namespace pages yet, so store them as Image:
	$cachedpage =~ s/^File:/Image:/;
	
	# Check to see if the page already exists, if it does has it been updated?
	my ($page_id, $last_revid) = page_in_cache($site, $cachedpage);

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

sub get_template
{
	my $text = shift;
	my $want_infobox = shift;

	my $ib;
	if ($want_infobox) {
		my ($prefix) = $text =~ /^(.*)\{\{\s*infobox/ism;
		return unless defined $prefix;
		$ib = extract_bracketed($text, '{}', quotemeta $prefix);
	}
	else {
		$ib = extract_bracketed($text, '{}');
	}

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

	my $tname = shift @tmplflds;
	$tname =~ s/^\s*//;
	$tname =~ s/\s*$//;
	$tname =~ s/\s/_/g;

	$tmplflds{template} = $tname unless exists $tmplflds{template};
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
	 "insert or ignore into redirects
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
		return;
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
	}

	return;
}

sub get_redirects
{
	my $page = shift;
	my $site = shift;
	my $verbose = shift;

	my @redirects;

	$page = uri_unescape($page);
	$page = uri_escape_utf8($page);

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
	my @allpages;

	$esobj->list( { action => 'query',
									list => 'allpages',
									aplimit => 'max',
									apfilterredir => 'nonredirects'
								}, { hook => sub { my $ref = shift; map { chomp;  s/^\s*//; s/\s*$//; push @allpages, $_ } @$ref; } }
							);

	print scalar @allpages . " Page Titles\n";
	return @allpages;
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

	my ($page_id) = $dbh->selectrow_array(
	 "select id
		from pages
		where title = ?
		and site_id = $site_id",

		undef,
		$title
	);

	if (defined $page_id) {
		$dbh->do(
		 "update pages
			set updated = 1
			where id = $page_id"
		);
	}
	else {	
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
	}

	my $revision_id = store_revision($dbh, $site_id, $page_id, 'ORIG', $text, $meta);

	# TODO: Need to decide what should happen if a category link used to exist, then was subsequently removed.
	# Should it be deleted here?
	my @cats = $text =~ /(\[\[Category:[^\]]*\]\])/ig;
	for my $cat (@cats) {
		$cat =~ s/\[\[Category:([^\]]*)\]\]/\1/i;

		$dbh->do(
		 "insert or ignore into categories
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

	my ($revision_id) = $dbh->selectrow_array(
	 "select id
		from revisions
		where page_id = $page_id
		and action = '$action'"
	);

	if (defined $revision_id) {		
		$dbh->do(
		 "update revisions
			set revid = $revid,
					revts = '$meta->{revts}'
			where id = $revision_id"
		);

		$dbh->do(
		 "update text
			set text = ?
			where revision_id = $revision_id",

			undef,
			$text
		);
	}
	else {
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

		$revision_id = $dbh->last_insert_id(undef, undef, undef, undef);

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
	}

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
	my $append = $opts->{append} || 0;
	my $level = shift || 0;

	unlink $sites->{$site}{file} if !$parent && !$append;

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
		if ($opts{rescan}) {
			rescan_page($site, $title);
		}
		else {
			process_page($site, $title);
		}
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
			my @images = ($nocomments =~ /\[\[((?:Image|File):[^\#\|\]]+)/gi);
			map {
				s/[^[:ascii:]]+//g;
				s/<!--.*?-->//g;
				s/Image:(.)/Image:\u\1/i;
				s/File:(.)/File:\u\1/i;

				my ($link_id) = $dbh->selectrow_array("select id from pages where title = '$_' and site_id = $site_id");
				# If not found, try again replacing spaces in title with underscores
				if (!defined $link_id) {
					s/\s/_/g;
					($link_id) = $dbh->selectrow_array("select id from pages where title = '$_' and site_id = $site_id");
				}
				# Still not found, try all underscores to spaces!
				if (!defined $link_id) {
					s/_/ /g;
					($link_id) = $dbh->selectrow_array("select id from pages where title = '$_' and site_id = $site_id");
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

sub merge_changes
{
	my $sitepair = shift;

	my ($from, $to) = split(/:/, uc $sitepair);

	$dbh->do(
	 "create temporary table tmp_wpcontrib_links
		as 
		select a.id as from_id, c.id as to_id
		from pages a
			inner join sites b
				on a.site_id = b.id
				and b.name = '$from'
			inner join pages c
				on a.title = c.title
			inner join sites d
				 on c.site_id = d.id
				 and d.name = '$to'
		where a.title like 'Template:WPContrib/%'"
	);

	$dbh->do(
	 "update text
		set text = (
			select text
			from text a
				inner join tmp_wpcontrib_links b
					on a.page_id = b.from_id
			where text.page_id = b.to_id
		)
		where exists (
			select 1
			from text a
				inner join tmp_wpcontrib_links b
					on a.page_id = b.from_id
			where text.page_id = b.to_id
		)"
	);

	print "Exporting $from...\n";
	export_pages({site => $from, updated => 0});
	print "Exporting $to...\n";
	export_pages({site => $to, updated => 0});
}

sub store_properties
{
	my $dbh = shift;
	my $site_id = shift;
	my $page_id = shift;
	my $tmplflds = shift;

	my $section = $tmplflds->{template};

	my ($section_id) = $dbh->selectrow_array(
	 "select id
		from properties
		where page_id = $page_id
		and key = '$section'
		and type = 1"
	);

	if (!defined $section_id) {
		$section_id = store_property($dbh, $site_id, $page_id, undef, 1, $section, undef);
	}

	# TODO: Need to decide what should happen if a template field used to exist, then was subsequently removed.
	# Should it be deleted here?
	while (my ($key,$val) = each %$tmplflds) {
		store_property($dbh, $site_id, $page_id, $section_id, 2, $key, $val);
	}
}

sub store_property
{
	my $dbh = shift;
	my $site_id = shift;
	my $page_id = shift;
	my $parent_id = shift;
	my $type = shift;
	my $key = shift;
	my $val = shift;

	$key = $dbh->quote($key);
	$val = (defined $val) ? $dbh->quote($val) : 'NULL';
	$parent_id = 'NULL' unless defined $parent_id;

	$dbh->do(
	 "insert or ignore into properties
		(
			page_id,
			site_id,
			parent_id,
			type,
			key, 
			value
		)
		values
		(
			$page_id,
			$site_id,
			$parent_id,
			$type,
			$key,
			$val
		)"
	);

	return $dbh->last_insert_id(undef, undef, undef, undef);
}
