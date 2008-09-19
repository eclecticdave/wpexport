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

my %cats;
my %tmplflds;
my %meta;

my $script=basename($0);
my $usage="Usage: $script [--<opts>]";

my %opts;
Getopt::Long::Configure("bundling");
GetOptions (\%opts,
	'db=s',
	'init',
  'merge',
	'imagehash',
	'getimages',
  'file=s',
  'page=s',
	'keeplinks:s',
	'redirects',
	'rebuild-klcache',
	'allpages'
) or die("$usage\nInvalid Option\n");

map { $opts{$_} = 0 if !exists($opts{$_}) } qw/merge imagehash getimages redirects rebuild-klcache allpages init/;

# Create a user agent object
my $ua = LWP::UserAgent->new;
$ua->agent("WPExport/0.1 ");

# Create MediaWiki::API objects
my $esobj = MediaWiki::API->new( { api_url => 'http://encoresoup.net/api.php' } );

my $dbname = $opts{db} || 'wpexport.db';

# Connect to local SQLite datacache
my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");

if ($opts{init}) {
	init_db();
}

# Reset 'updated' flags
$dbh->do("update pages set updated = 0");

unlink "wp.txt";
unlink "esplus.txt";
unlink "es.txt" if $opts{merge};

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
	process_page($page);
}

$dbh->disconnect();
exit 0;

sub process_page
{
	my $page = shift;

	my $isimage;
	my $filter;

	undef %tmplflds;

	chomp $page;

	print "Processing Page: $page\n";

	$isimage = ($page =~ /^Image:/i) ? 1 : 0;
	$filter = ($isimage) ? 3 : 1;

	# Get Details from Encoresoup for merging.
	my $esxml;
	my $es_latest_release_version = '';
	my $es_latest_release_date = '';
	my $es_latest_preview_version = '';
	my $es_latest_preview_date = '';
	my $espage = '';
	if ($opts{merge}) {
		print "\tExporting From Encoresoup\n";
		$esxml = export_page('ES', $page);

		# Parse the XML.
		my $estext = parse_export_xml($esxml, "es.txt", 0);
		store_page($dbh, 'ES', $page, $estext, \%tmplflds);

		# Get Encoresoup Version Templates
		undef %tmplflds;
		my $esver = export_page('ES', "Template:Latest_stable_release/$page");
		my $vertext = parse_export_xml($esver, undef, 2);
		store_page($dbh, 'ES', "Template:Latest_stable_release/$page", $vertext, \%tmplflds);

		if (exists $tmplflds{release_version}) {
			$es_latest_release_version = $tmplflds{release_version};
			print "\tES: Latest Release Version: $es_latest_release_version\n";
		}
		if (exists $tmplflds{release_date}) {
			$es_latest_release_date = $tmplflds{release_date};
			print "\tES: Latest Release Date: $es_latest_release_date\n";
		}

		undef %tmplflds;
		$esver = export_page('ES', "Template:Latest_preview_release/$page");
		$vertext = parse_export_xml($esver, undef, 2);
		store_page($dbh, 'ES', "Template:Latest_preview_release/$page", $vertext, \%tmplflds);

		if (exists $tmplflds{release_version}) {
			$es_latest_preview_version = $tmplflds{release_version};
			print "\tES: Latest Preview Version: $es_latest_preview_version\n";
		}
		if (exists $tmplflds{release_date}) {
			$es_latest_preview_date = $tmplflds{release_date};
			print "\tES: Latest Preview Date: $es_latest_preview_date\n";
		}

		# Add redirects
		if ($opts{redirects}) {
			my @redirs = get_redirects($page,'ES',1);
			map { create_redirect_text($page, 'ES', $_) } @redirs;
		}

		# Change page name to retrieve from Wikipedia if {{Wikipedia-Attrib}} template is used.
		my ($wppage) = $estext =~ /\{\{Wikipedia-Attrib\|(.*?)\}\}/i;

		if ($page ne $wppage) {
			print "\tPage On Wikipedia: $wppage\n";
			$espage = $page;
			$page = $wppage;
		}
	}

	print "\tExporting From Wikipedia\n";
	my $wpxml = export_page('WP', $page);

	# Pass in reference to $realpage, gets correct title if we supplied a redirect.
	my $realpage;
	my $text = parse_export_xml($wpxml, "wp.txt", $filter, \$realpage);
	store_page($dbh, 'WP', $realpage, $text, \%tmplflds);

	if (!defined $text) {
		# undef returned only for images, where 'missing' attributes is set.
		# - indicates image description is on Wikimedia Commons.
		print "\tExporting From Wikimedia Commons\n";
		my $wpxml = export_page('CO', $page);
		$text = parse_export_xml($wpxml, "wp.txt", $filter, \$realpage);
		store_page($dbh, 'WP', $realpage, $text, \%tmplflds);
	}

	if ($page ne $realpage) {
		print "\tActual Page Title: $realpage\n";
		$page = $realpage;
	}

	# Extract Versions from WP Page.
	my $wp_latest_release_version = '';
	my $wp_latest_release_date = '';
	my $wp_latest_preview_version = '';
	my $wp_latest_preview_date = '';

	if ($tmplflds{frequently_updated} =~ /yes/i) {
		print "\tNEED TO GET VERSION TEMPLATE!!\n\n";

		undef %tmplflds;
		my $wpver = export_page('WP', "Template:Latest_stable_release/$page");
		parse_export_xml($wpver, undef, 2);

		if (exists $tmplflds{latest_release_version}) {
			$wp_latest_release_version = $tmplflds{latest_release_version};
			print "\tWP: Latest Release Version: $wp_latest_release_version\n";
		}
		if (exists $tmplflds{latest_release_date}) {
			$wp_latest_release_date = $tmplflds{latest_release_date};
			print "\tWP: Latest Release Date: $wp_latest_release_date\n";
		}

		undef %tmplflds;
		$wpver = export_page('WP', "Template:Latest_preview_release/$page");
		parse_export_xml($wpver, undef, 2);

		if (exists $tmplflds{latest_release_version}) {
			$wp_latest_preview_version = $tmplflds{latest_release_version};
			print "\tWP: Latest Preview Version: $wp_latest_preview_version\n";
		}
		if (exists $tmplflds{latest_release_date}) {
			$wp_latest_preview_date = $tmplflds{latest_release_date};
			print "\tWP: Latest Preview Date: $wp_latest_preview_date\n";
		}
	}
	else {
		if (exists $tmplflds{latest_release_version}) {
			$wp_latest_release_version = $tmplflds{latest_release_version};
			print "\tWP: Latest Release Version: $wp_latest_release_version\n";
		}
		if (exists $tmplflds{latest_release_date}) {
			$wp_latest_release_date = $tmplflds{latest_release_date};
			print "\tWP: Latest Release Date: $wp_latest_release_date\n";
		}
		if (exists $tmplflds{latest_preview_version}) {
			$wp_latest_preview_version = $tmplflds{latest_preview_version};
			print "\tWP: Latest Preview Version: $wp_latest_preview_version\n";
		}
		if (exists $tmplflds{latest_preview_date}) {
			$wp_latest_preview_date = $tmplflds{latest_preview_date};
			print "\tWP: Latest Preview Date: $wp_latest_preview_date\n";
		}
	}

	# Create Release templates for versions if they exist on WP and are different to on ES (always true if ES
	# versions not retrieved)
	if (($wp_latest_release_version && ($es_latest_release_version ne $wp_latest_release_version))
			|| ($wp_latest_release_date && ($es_latest_release_date ne $wp_latest_release_date))) {
		print "\tEncoresoup Latest Release is Out Of Date!!\n";
		create_release_template($page, 'Latest_stable_release', $wp_latest_release_version, $wp_latest_release_date);
	}
	if (($wp_latest_preview_version && ($es_latest_preview_version ne $wp_latest_preview_version))
			|| ($wp_latest_preview_date && ($es_latest_preview_date ne $wp_latest_preview_date))) {
		print "\tEncoresoup Latest Preview is Out Of Date!!\n";
		create_release_template($page, 'Latest_preview_release', $wp_latest_preview_version, $wp_latest_preview_date);
	}

	my $image_src;

	# If we are getting a Image: page, then go get the corresponding image file
	$image_src = get_image($page) if ($isimage);

	# Do Wikipedia Revision Info Export
	if (!$isimage || $image_src ne 'F') {
		get_contributors($page, $image_src);
	}

	# Add redirects
	if ($opts{redirects}) {
		print "\tCreating Redirect Pages\n";
		my @redirs = get_redirects($page,'WP',1);
		# Redirect should point to page on Encoresoup, if different to Wikipedia Title.
		map { create_redirect_text(($espage) ? $espage : $page, 'WP', $_) } @redirs;
	}
}

sub get_contributors
{
	my $page = shift;
	my $image_src = shift;

	print "\tExporting Contributors from Wikipedia...\n";

	my $file = 'esplus.txt';

	open FH, ">>:utf8", $file;

	my %contribs;

	# Get details from Wikimedia commons if we just got an image from there.
	my $wpapi;
	$wpapi = ($image_src eq 'CO') ? "http://commons.wikimedia.org/w/api.php"
				 : "http://en.wikipedia.org/w/api.php";
	my $q = "action=query&prop=revisions&titles=$page&rvlimit=max&rvprop=user&format=xml";
	my $xml = do_query($wpapi, $q);
	my $revstartid = parse_rev_xml($xml, \%contribs);
	while($revstartid != 0) {
		$xml = do_query($wpapi, $q . '&rvstartid=' . $revstartid);
		$revstartid = parse_rev_xml($xml, \%contribs);
	}

	my $normpage = $page;
	$normpage =~ s/:/_/g;

	my $linkpage = $page;
	$linkpage = ':' . $page if $page =~ /^Image:/i;

	print FH "{{-start-}}\n'''Template:WPContrib/$normpage'''\n";
	print FH "== $page - Wikipedia Contributors ==\n\n";
	print FH "''The following people have contributed to the [[$linkpage]] article on Wikipedia, prior to it being imported into Encoresoup''\n\n";
	print FH "<div class=\"references-small\" style=\"-moz-column-count:3; -webkit-column-count:3; column-count:3;\">\n";
	print FH '*' . join("\n*", map { (/^[\d\.]*$/) ? "[[w:Special:Contributions/$_|$_]]" : "[[w:User:$_|$_]]" } sort(keys(%contribs)));
	print FH "\n</div>\n";
	print FH "{{-stop-}}\n";

	close FH;
}

sub parse_export_xml
{
	my $xml = shift;
	my $file = shift;
	my $filter = shift;
	my $realpage = shift; # Must be a reference;

	my $title = "";
	my $text = "";
	my $rev = "";
	my $revid = 0;
	my $revts = "";
	my $missing = 0;

	my %pages;

	my $twig = XML::Twig->new(
	 	twig_handlers =>
			{ 
			  'revisions/rev' => sub
					{
						$rev = $_->text;
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
					  $text .= "{{-start-}}\n'''" . $title . "'''\n";
						$pages{$title}[$filter] = process_text($title, $rev, $filter);
						$text .= $pages{$title}[$filter] . "\n{{-stop-}}\n";
					}
			},
		pretty_print => 'indented'
	);
	$twig->parse($xml);

	return undef if $missing;

	if ($file) {
		open(FH, ">>:utf8", $file);
		print FH $text;
		close FH;
	}

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
	my $filter = shift;

	if ($filter == 1) {
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

		# Replace Categories with marker
		$text =~ s/\[\[Category:[^\]]*\]\]/\%marker\%/gi;

		# Replace first Marker with Encoresoup Categories
		$text =~ s/\%marker\%/$cats{$title}/;
		
		# Remove other markers
		$text =~ s/\%marker\%//g;

		# Comment out language links
		$text =~ s/\[\[([a-z][a-z]|ast|simple):([^\]]*)\]\]/<!--[[$1:$2]]-->/gi;

		# Identify Images
		if ($opts{getimages}) {
			my @images = ($text =~ /\[\[(Image:[^\#\|\]]+)/gi);
			map { s/[^[:ascii:]]+//g; push @pages, $_; } @images;
		}

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
	elsif ($filter == 0) {
		# Processing Encoresoup Extract (must be done first!) ...

		# Extract Categories
		my @cats = $text =~ /(\[\[Category:[^\]]*\]\])/ig;
		$cats{$title} = join("\n", @cats);
	}
	elsif ($filter == 2) {
		my $ib = extract_bracketed($text, '{}');
		get_template_fields($ib);
	}
	elsif ($filter == 3) {
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

	return $text;
}

sub export_page
{
	my $site = shift;
	my $page = shift;
	my $file = shift;

	my $wpapi = "http://en.wikipedia.org/w/api.php";
	my $esapi = "http://encoresoup.net/api.php";
	my $coapi = "http://commons.wikimedia.org/w/api.php";

	my $url = ($site eq 'WP') ? $wpapi
		: ($site eq 'CO') ? $coapi : $esapi;

	my $q = "action=query&prop=revisions&titles=$page&rvlimit=1&rvprop=content|ids|timestamp&redirects=1&format=xml";
	return do_query($url, $q, $file);
}

sub do_query
{
	my $url = shift;
	my $q = shift;
	my $file = shift;

	my $req = HTTP::Request->new(POST => $url);
	$req->content_type('application/x-www-form-urlencoded');
	$req->content($q);

	my $res = $ua->request($req);

	# Check the outcome of the response
	if ($res->is_success) {
		my $xml = $res->content;
		$xml =~ s/^\s*//;
		if (defined $file) {
			open FH, '>:utf8', $file;
			print FH $xml;
			close FH;
		}
		else {
			return $xml;
		}
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

	my $file = ($site eq 'WP') ? 'wp.txt' : 'es.txt';

	open FH, ">>:utf8", $file;

	print FH <<EOF
{{-start-}}
'''$redir'''
#REDIRECT [[$page]]
{{-stop-}}
EOF
;

	close FH;

	$dbh->do(
	 "insert into redirects
		(
		  pages_id,
			title
		)
		select
			id,
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

	$dbh->do(
	 "update pages
		set text = ?,
				revid = $meta{revid},
				revts = '$meta{revts}',
		    updated = 1
		where title = ?
		and revid < $meta{revid}",

		undef,
		$text, $title
	);

	$dbh->do(
	 "insert into pages
	 	(
			sites_id,
			title,
			text,
			revid,
			revts,
			updated
		)
		select
			id,
			?,
			?,
			$meta{revid},
			'$meta{revts}',
			1
		from sites
		where name = '$site'
		and not exists
		(
		  select 1
			from pages
			where title = ?
		)",

		undef,
		$title,
		$text,
		$title
	);

	my $pages_id = $dbh->last_insert_id(undef, undef, undef, undef);
	my $tname = $tmplflds->{template};
	$dbh->do(
	 "insert into templates
		(
			pages_id,
			name
		)
		values
		(
			$pages_id,
			'$tname'
		)"
	);

	my $templates_id = $dbh->last_insert_id(undef, undef, undef, undef);

	while (my ($key,$val) = each %$tmplflds) {
		$dbh->do(
		 "insert into tmplflds
			(
				templates_id,
				field, 
				value
			)
			values
			(
				$templates_id,
				'$key',
				'$val'
			)"
		);
	}
}

sub init_db
{
	$dbh->do(
		"CREATE TABLE sites (
    id INTEGER PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    file TEXT
		)"
	);

	$dbh->do(
	 "CREATE TABLE pages (
    id INTEGER PRIMARY KEY NOT NULL,
    sites_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    text TEXT,
		revid INTEGER,
		revts TEXT,
		updated INTEGER
		)"
	);

	$dbh->do(
	 "CREATE TABLE templates (
    id INTEGER PRIMARY KEY NOT NULL,
    pages_id INTEGER NOT NULL,
    name TEXT NOT NULL
		)"
	);

	$dbh->do(
	 "CREATE TABLE tmplflds (
    id INTEGER PRIMARY KEY NOT NULL,
    templates_id INTEGER NOT NULL,
    field TEXT NOT NULL,
    value TEXT
		)"
	);

	$dbh->do(
	 "CREATE TABLE redirects (
    id INTEGER PRIMARY KEY NOT NULL,
    pages_id INTEGER NOT NULL,
    title TEXT
		)"
	);

	$dbh->do(
	 "insert into sites
		(
			name,
			url,
			file
		)
		values
		(
			'ES',
			'encoresoup.net',
			'es.txt'
		)"
	);

	$dbh->do(
	 "insert into sites
		(
			name,
			url,
			file
		)
		values
		(
			'WP',
			'en.wikipedia.org/w',
			'wp.txt'
		)"
	);

	$dbh->do(
	 "insert into sites
		(
			name,
			url,
			file
		)
		values
		(
			'CO',
			'commons.wikimedia.org/w',
			null
		)"
	);
}
