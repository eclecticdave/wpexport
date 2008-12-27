CREATE TABLE sites (
  id INTEGER PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  url TEXT NOT NULL,
  file TEXT,
	desc TEXT,

	UNIQUE (name)
);

CREATE TABLE pages (
  id INTEGER PRIMARY KEY NOT NULL,
  site_id INTEGER NOT NULL,
  title TEXT NOT NULL,
	updated INTEGER,
	latest_action TEXT,
	parent_id INTEGER,
	parent_page TEXT,

	UNIQUE (site_id, title)
);

CREATE TABLE revisions (
	id INTEGER PRIMARY KEY NOT NULL,
	page_id INTEGER NOT NULL,
	site_id INTEGER NOT NULL,
	revid INTEGER,
	revts TEXT,
	action TEXT,
	updated INTEGER,

	UNIQUE (page_id, action)
);

CREATE TABLE text (
	id INTEGER PRIMARY KEY NOT NULL,
	revision_id INTEGER NOT NULL,
	page_id INTEGER NOT NULL,
	site_id INTEGER NOT NULL,
	text TEXT,

	UNIQUE (revision_id)
);

CREATE TABLE templates (
  id INTEGER PRIMARY KEY NOT NULL,
  page_id INTEGER NOT NULL,
	site_id INTEGER NOT NULL,
  name TEXT NOT NULL,

	UNIQUE (page_id, name)
);

CREATE TABLE tmplflds (
  id INTEGER PRIMARY KEY NOT NULL,
  template_id INTEGER NOT NULL,
  page_id INTEGER NOT NULL,
	site_id INTEGER NOT NULL,
  field TEXT NOT NULL,
  value TEXT,

	UNIQUE (template_id, field)
);

CREATE TABLE redirects (
  id INTEGER PRIMARY KEY NOT NULL,
  page_id INTEGER NOT NULL,
	site_id INTEGER NOT NULL,
  title TEXT,

	UNIQUE (page_id, title)
);

CREATE TABLE categories (
	id INTEGER PRIMARY KEY NOT NULL,
	revision_id INTEGER NOT NULL,
	page_id INTEGER NOT NULL,
	site_id INTEGER NOT NULL,
	name TEXT,

	UNIQUE (revision_id, name)
);

CREATE TABLE pagelinks (
  id INTEGER PRIMARY KEY NOT NULL,
  site_id_parent INTEGER NOT NULL,
  page_id_parent INTEGER NOT NULL,
  site_id_child INTEGER NOT NULL,
  page_id_child INTEGER NOT NULL
);

create index pagelinks_idx1 on pagelinks
  (site_id_child, page_id_child, site_id_parent, page_id_parent);

insert into sites
(
		name,
		url,
		file,
		desc
)
values
(
		'ES',
		'encoresoup.net',
		'es.txt',
		'Encoresoup'
);

insert into sites
(
		name,
		url,
		file,
		desc
)
values
(
		'WP',
		'en.wikipedia.org/w',
		'wp.txt',
		'Wikipedia'
);

insert into sites
(
		name,
		url,
		file,
		desc
)
values
(
		'CO',
		'commons.wikimedia.org/w',
		'co.txt',
		'Wikimedia Commons'
);

create view titles
as
select site_id, id as page_id, title, 0 as redirect_id
from pages
where parent_id is null
union all
select a.site_id, a.page_id, a.title, a.id as redirect_id
from redirects a
  inner join pages b
    on a.page_id = b.id
where b.parent_id is null;
 
.quit

