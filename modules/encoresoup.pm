#
# Extension module for wpexport.pl - handles all Encoresoup specifics
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

package encoresoup;

use Text::Balanced qw ( extract_bracketed );
use Date::Manip;

sub new
{
	my $class = shift;
	my $wpexp = shift;

	my $self = {};

	$self->{WPEXP} = $wpexp;

	bless ($self, $class);
	return $self;
}

sub process_page
{
	my $self = shift;

	my $title = shift;
	my $site = shift;
  my $text = shift;
  my $page_id = shift;
	my $properties = shift;

	# We are only interested in pages from Wikipedia, not our own pages!
	return undef if $site eq 'ES';

	$text = $self->_process_text($title, $site, $text, $page_id);

	$self->_get_infobox_info($text,$properties);
	return $text;
}

sub _process_text
{
	my $self = shift;

	my $title = shift;
	my $site = shift;
  my $text = shift;
  my $page_id = shift;

	my $wpexp = $self->{WPEXP};

	# Try to locate equivalent page on Encoresoup
	my $link_page_id = $wpexp->create_page_link($site, $page_id, 'ES');
	print "\tPage Linked to $title (id = $page_id) is id $link_page_id\n";

	my $isimage = ($title =~ /^(?:Image|File):/i) ? 1 : 0;

	if ($isimage) {
		# Unlink Wiki-links
		$text =~ s/\[\[[^\]:]*?\|(.*?)\]\]/\1/g;
		$text =~ s/\[\[([^\]:]*?)\]\]/\1/g;

		# Comment-out Categories
		$text =~ s/(\[\[Category:[^\]]*\]\])/<!-- \1 -->/gi;

		# Add Wikipedia-Attrib-Image template if it doesn't already exist
		my $image = $title;
		$image =~ s/^(?:Image|File)://i;
		$text .= "\n{{Wikipedia-Attrib-Image|$image}}" unless $text =~ /\{\{Wikipedia-Attrib-Image/i;
	}
	else {
		# Processing Wikipedia Extract ...

		# Unlink Wiki-links
		$text =~ s/\[\[([^\]:]*?)\|(.*?)\]\]/$wpexp->process_link($1,$2)/ge;
		$text =~ s/\[\[([^\]\|:]*?)\]\]/$wpexp->process_link($1)/ge;

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
			my $catsref = $wpexp->get_categories($link_page_id, 'ES');

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

sub _get_infobox_info
{
	my $self = shift;

	my $text = shift;
	my $properties = shift;

	$self->_get_template($text,1,$properties);
}

sub _get_template
{
	my $self = shift;

	my $text = shift;
	my $want_infobox = shift;

	my $properties = shift;

	my $ib;
	if ($want_infobox) {
		my ($prefix) = $text =~ /^(.*)\{\{\s*infobox/ism;
		return unless defined $prefix;
		$ib = extract_bracketed($text, '{}', quotemeta $prefix);
	}
	else {
		$ib = extract_bracketed($text, '{}');
	}

	my ($tname, $tmplflds) = $self->_get_template_fields($ib);

	$tname = 'infobox' if $want_infobox;

	$properties->{$tname} = $tmplflds;
}

sub _get_template_fields
{
	my $self = shift;

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

	#$tmplflds{template} = $tname unless exists $tmplflds{template};
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

	return ($tname, \%tmplflds);
}

# Create additional pages associated with main page from Wikipedia.
sub additional_pages
{
	my $self = shift;

	my $site = shift;
	my $parent_page = shift;
	my $parent_page_id = shift;
	my $properties = shift;

	$self->_create_contrib_page($site, $parent_page, $parent_page_id, $properties) unless $site eq 'ES';

	if (($properties->{infobox}{frequently_updated} =~ /yes/i) || ($site eq 'ES'))
	{
		$self->_process_version_templates($site, $parent_page, $parent_page_id, $properties);
	}

	$self->_create_release_templates($site, $parent_page, $parent_page_id, $properties);
}

sub _create_contrib_page
{
	my $self = shift;

	my $site = shift;
	my $parent_page = shift;
	my $parent_page_id = shift;
	my $properties = shift;

	my $wpexp = $self->{WPEXP};

	my $contrib_page = "Template:WPContrib/$parent_page";

	my $text;

	return if ($site eq 'ES');

	my $contribs = $wpexp->get_contributors($site, $parent_page);

	my $linkpage = $parent_page;
	$linkpage = ':' . $parent_page if $parent_page =~ /^(?:Image|File):/i;

	$text = <<EOF
== $parent_page - Wikipedia Contributors ==

''The following people have contributed to the [[$linkpage]] article on Wikipedia, prior to it being imported into Encoresoup''
<div class=\"references-small\" style=\"-moz-column-count:3; -webkit-column-count:3; column-count:3;\">
EOF
;

	$text .= '*' . join("\n*", map { (/^[\d\.]*$/) ? "[[w:Special:Contributions/$_|$_]]" : "[[w:User:$_|$_]]" } sort(keys(%$contribs)));
	$text .= "\n</div>\n";

	print "Storing $contrib_page\n";
	$wpexp->store_page($site, $contrib_page, $text, $parent_page_id, $parent_page);
}

sub _process_version_templates
{
	my $self = shift;

	my $site = shift;
	my $parent_page = shift;
	my $parent_page_id = shift;
	my $properties = shift;

	my $wpexp = $self->{WPEXP};

	for my $tmpl ('stable','preview') {
		my %meta;
		my %props;
		my $tmpl_page = $meta{cachedpage} = "Template:Latest $tmpl release/$parent_page";
		print "\tRetrieving $tmpl_page\n";
		my $text = $wpexp->get_page($site, "$tmpl_page", \%meta);
		if (!exists $meta{missing}) {
			$self->_get_template($text,0,\%props);

			my $latest_release_version = $props{latest_release_version} || $props{release_version};
			my $latest_release_date = $props{latest_release_date} || $props{release_date};

			$latest_release_version =~ s/\[http:[^\s]*\s([^\]]*)\]/\1/; # Remove download wikilink

			$latest_release_date =~ s/\[\[([^\]]*)\]\]/\1/g; # Delink wikilinks
			$latest_release_date =~ s/release date and age/release_date/;
			$latest_release_date =~ s/release date/release_date/;
			$latest_release_date =~ s/release_date\|(mf|df)=(.*?)\|/release_date\|/;

			$properties->{infobox}{"latest_${tmpl}_version"} = $latest_release_version;
			$properties->{infobox}{"latest_${tmpl}_date"} = $latest_release_date;
		}
	}
}

sub _create_release_templates
{
	my $self = shift;

	my $site = shift;
	my $parent_page = shift;
	my $parent_page_id = shift;
	my $properties = shift;

	my $wpexp = $self->{WPEXP};

	my $latest_release_version = $properties->{infobox}{latest_release_version};
	my $latest_release_date = $properties->{infobox}{latest_release_date};
	my $latest_preview_version = $properties->{infobox}{latest_preview_version};
	my $latest_preview_date = $properties->{infobox}{latest_preview_date};

	if ($latest_release_version) {
		my $text = $self->_create_release_template($parent_page, 'Latest stable release', $latest_release_version, $latest_release_date);
		$wpexp->store_page($site, "Template:Latest stable release/$page", $text, $parent_page_id, $parent_page);
	}
	if ($latest_preview_version) {
		my $text = $self->_create_release_template($parent_page, 'Latest preview release', $latest_preview_version, $latest_preview_date);
		$wpexp->store_page($site, "Template:Latest preview release/$page", $text, $parent_page_id, $parent_page);
	}
}

sub _create_release_template
{
	my $self = shift;

	my $title = shift;
	my $type = shift;
	my $version = shift;
	my $date = shift;

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

1;
