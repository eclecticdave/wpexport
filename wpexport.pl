#! /usr/bin/perl

#
# Script to get wikipedia pages and prepare them for merging with encoresoup.
#
# Usage: perl wpexport.pl [--merge] [--file <file>] [--page <page title>]
# Options:
#   --merge     Retrieves matching pages from encoresoup into es.txt to facilitate manual merging.
#   --file      Specifies File containing list of page titles, one per line.
#   --page      Specifies Page Title to retrieve.
#   --imagehash Image files will be downloaded to subdirectories based on MD5 hash on filename.
#               (mirroring structure expected by mediawiki software - not really useful for non-admins)
#
#   One of --file or --page must be supplied
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

use File::Basename;
use File::Slurp;
use LWP::UserAgent;
use XML::Twig;
use Text::Balanced qw ( extract_bracketed );
use Date::Manip;
use Getopt::Long;
use MD5;

my %cats;
my %tmplflds;

my $script=basename($0);
my $usage="Usage: $script [--<opts>]";

Getopt::Long::Configure("bundling");
GetOptions (\%opts,
  'merge',
	'imagehash',
  'file=s',
  'page=s'
) or die("$usage\nInvalid Option\n");

map { $opts{$_} = 0 if !exists($opts{$_}) } qw/merge imagehash/;

# Create a user agent object
$ua = LWP::UserAgent->new;
$ua->agent("WPExport/0.1 ");

unlink "wp.txt";
unlink "esplus.txt";
unlink "es.txt" if $opts{merge};

my @pages;
if ($opts{file}) {
	@pages = read_file($opts{file});
}
elsif ($opts{page}) {
	@pages = ($opts{page});
}
else {
	print STDERR "Either --file or --page must be supplied\n\n";
}

for my $page (@pages) {
	my $isimage;
	my $filter;

	chomp $page;

	print "Processing Page: $page\n";

	$isimage = ($page =~ /^Image:/i) ? 1 : 0;

	print "\tExporting From Wikipedia\n";
	my $wpxml = export_page('WP', $page);

	my $esxml;
	if ($opts{merge}) {
		print "\tExporting From Encoresoup\n";
		$esxml = export_page('ES', $page);
	}

	$filter = ($isimage) ? 3 : 1;

	# Parse the XML.
	parse_export_xml($esxml, "es.txt", 0) if ($opts{merge});
	parse_export_xml($wpxml, "wp.txt", $filter);

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

	my $es_latest_release_version = '';
	my $es_latest_release_date = '';
	my $es_latest_preview_version = '';
	my $es_latest_preview_date = '';

	if ($opts{merge}) {
		# Get Encoresoup Version Templates
		
		undef %tmplflds;
		my $esver = export_page('ES', "Template:Latest_stable_release/$page");
		parse_export_xml($esver, undef, 2);

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
		parse_export_xml($esver, undef, 2);

		if (exists $tmplflds{release_version}) {
			$es_latest_preview_version = $tmplflds{release_version};
			print "\tES: Latest Preview Version: $es_latest_preview_version\n";
		}
		if (exists $tmplflds{release_date}) {
			$es_latest_preview_date = $tmplflds{release_date};
			print "\tES: Latest Preview Date: $es_latest_preview_date\n";
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

	# Do Wikipedia Revision Info Export
	get_contributors($page);

	# If we are getting a Image: page, then go get the corresponding image file
	get_image($page) if ($isimage);
}

exit 0;

sub get_contributors
{
	my $page = shift;

	print "\tExporting Contributors from Wikipedia...\n";

	my $file = 'esplus.txt';

	open FH, ">>:utf8", $file;

	my %contribs;
	my $wpapi = "http://en.wikipedia.org/w/api.php";
	my $q = "action=query&prop=revisions&titles=$page&rvlimit=max&rvprop=user&format=xml";
	my $xml = do_query($wpapi, $q);
	$revstartid = parse_rev_xml($xml, \%contribs);
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

	my $title = "";
	my $text = "";
	my $rev = "";

	my $twig = XML::Twig->new(
	 	twig_handlers =>
			{ 
			  'revisions/rev' => sub { $rev = $_->text; },
				'page' => sub
					{ $title = $_->att('title');
					  $text .= "{{-start-}}\n'''" . $title . "'''\n";
						$pages{$title}[$filter] = process_text($title, $rev, $filter);
						$text .= $pages{$title}[$filter] . "\n{{-stop-}}\n";
					}
			},
		pretty_print => 'indented'
	);
	$twig->parse($xml);

	if ($file) {
		open(FH, ">>:utf8", $file);
		print FH $text;
		close FH;
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

sub process_text
{
	my $title = shift;
  my $text = shift;
	my $filter = shift;

	if ($filter == 1) {
		# Processing Wikipedia Extract ...

		# Unlink Wiki-links
		$text =~ s/\[\[[^\]:]*?\|(.*?)\]\]/\1/g;
		$text =~ s/\[\[([^\]:]*?)\]\]/\1/g;

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

	my $wpurl = "http://en.wikipedia.org/w/index.php";
	my $esurl = "http://encoresoup.net/index.php";
	my $wpapi = "http://en.wikipedia.org/w/api.php";
	my $esapi = "http://encoresoup.net/api.php";

	#my $url = ($site eq 'WP') ? $wpurl : $esurl;
	my $url = ($site eq 'WP') ? $wpapi : $esapi;

	my $q = "action=query&prop=revisions&titles=$page&rvlimit=1&rvprop=content&redirects=1&format=xml";
	#my $q = "title=Special:Export&curonly=1&limit=1&dir=desc&redirects=1&pages=$page";
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
			#write_file ($file, $res->content);
		}
		else {
			return $xml;
		}
	}
	else {
		 print $res->status_line, "\n";
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

sub get_image
{
	my $page = shift;

	my $wppath;
	my $espath;

	# Remove Image: prefix
	$page =~ s/^Image://i;

	# Create image subdirectory if necessary
	mkdir "images" unless -d "images";

	# Calculate where Wikipedia will be storing the image.
	my $md5 = MD5->hexhash($page);
	my ($prefix1) = $md5 =~ /^(.)/;
	my ($prefix2) = $md5 =~ /^(..)/;

	if ($opts{imagehash}) {
		# Create image hash directories if necessary
		mkdir "images/$prefix1" unless -d "images/$prefix1";
		mkdir "images/$prefix1/$prefix2" unless -d "images/$prefix1/$prefix2";

		$wppath = "$prefix1/$prefix2/$page";
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
}
