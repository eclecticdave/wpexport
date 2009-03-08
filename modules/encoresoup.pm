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
	my $dbh = shift;

	my $self = {};

	# Cache 'sites' table into hashref
	$self->{SITES} = $dbh->selectall_hashref("select * from sites", 'name');

	# Cache valid page titles into 'keeplinks' hashref
	my $keeplinks = $dbh->selectall_arrayref("select distinct title from titles");
	my %keeplinks = map { lc $_->[0] => 1 } (@$keeplinks);
	$self->{KEEPLINKS} = \%keeplinks;

	bless ($self, $class);
	return $self;
}

sub process_text
{
	my $self = shift;

	my $dbh = shift;
	my $title = shift;
	my $site = shift;
  my $text = shift;
  my $page_id = shift;

	# Try to locate equivalent page on Encoresoup
	my $link_page_id = $self->_link_matching_page($dbh, $site, $title, $page_id);
	print "\tPage Linked to $title (id = $page_id) is id $link_page_id\n";

	my $es_site_id = $self->{SITES}{ES}{id};

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
		$text =~ s/\[\[([^\]:]*?)\|(.*?)\]\]/$self->_process_link($1,$2)/ge;
		$text =~ s/\[\[([^\]\|:]*?)\]\]/$self->_process_link($1)/ge;

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

sub _process_link
{
	my $self = shift;

	my $link = shift;
	my $desc = shift;

	$link =~ s/^\s*//;
	$link =~ s/\s*$//;

	if ($self->{KEEPLINKS}{lc $link}) {
		return (defined $desc) ? "[[$link|$desc]]" : "[[$link]]";
	}
	else {
		return (defined $desc) ? $desc : $link;
	}
}

sub _link_matching_page
{
	my $self = shift;

	my $dbh = shift;
	my $site = shift;
	my $page = shift;
	my $page_id = shift;

	my $site_id = $self->{SITES}{$site}{id};
	my $es_site_id = $self->{SITES}{ES}{id};

	my $link_page_id = 0;

	($link_page_id) = $dbh->selectrow_array(
	 "select id
	  from pages
		where title = ?
		and site_id = $es_site_id",

		undef,
		$page
	);

	if (!$link_page_id) {
		# There might be a redirect with the matching title
		($link_page_id) = $dbh->selectrow_array(
		 "select page_id
			from redirects
			where title = ?
			and site_id = $es_site_id",

			undef,
			$page
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

	return $link_page_id if $count;

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

1;
