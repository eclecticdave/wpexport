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

sub new
{
	my $class = shift;
	my $wpexp = shift;

	my $self = {};

	$self->{WPEXP} = $wpexp;

	bless ($self, $class);
	return $self;
}

sub process_text
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

1;
