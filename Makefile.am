CLEANFILES=	$(dist_rc_SCRIPTS)

awkdir=	$(pkgdatadir)/awk
htmldir= $(pkgdatadir)/html
includedir= $(pkgdatadir)/include
assetsdir= $(htmldir)/assets
bootstrapdir= $(assetsdir)/bootstrap
btcssdir= $(bootstrapdir)/css
btjsdir= $(bootstrapdir)/js
btfontsdir= $(bootstrapdir)/fonts
datatablesdir= $(assetsdir)/dataTables
dtcssdir= $(datatablesdir)/css
dtimagesdir= $(datatablesdir)/images
dtjsdir= $(datatablesdir)/js
rcdir= $(sysconfdir)/rc.d
hookdir= $(sysconfdir)/poudriere.d/hooks
mandir= $(prefix)/man

dist_bin_SCRIPTS=	src/bin/poudriere

dist_man_MANS=	src/bin/poudriere.8

sysconf_DATA=	src/etc/poudriere.conf.sample \
		src/etc/poudriered.conf.sample

hook_DATA=	src/etc/poudriere.d/hooks/bulk.sh.sample \
		src/etc/poudriere.d/hooks/pkgbuild.sh.sample

dist_pkgdata_DATA=	src/share/poudriere/bulk.sh \
			src/share/poudriere/clean.sh \
			src/share/poudriere/common.sh \
			src/share/poudriere/daemon.sh \
			src/share/poudriere/distclean.sh \
			src/share/poudriere/jail.sh \
			src/share/poudriere/options.sh \
			src/share/poudriere/pkgclean.sh \
			src/share/poudriere/ports.sh \
			src/share/poudriere/processonelog.sh \
			src/share/poudriere/queue.sh \
			src/share/poudriere/status.sh \
			src/share/poudriere/testport.sh

dist_include_HEADERS= \
			src/share/poudriere/include/common.sh.dragonfly \
			src/share/poudriere/include/common.sh.freebsd \
			src/share/poudriere/include/display.sh \
			src/share/poudriere/include/html.sh \
			src/share/poudriere/include/hash.sh \
			src/share/poudriere/include/fs.sh \
			src/share/poudriere/include/messages.sh \
			src/share/poudriere/include/parallel.sh

dist_awk_DATA= src/share/poudriere/awk/dependency_loop.awk \
		src/share/poudriere/awk/humanize.awk \
		src/share/poudriere/awk/json.awk \
		src/share/poudriere/awk/processonelog2.awk \
		src/share/poudriere/awk/siginfo_buildtime.awk

dist_html_DATA= src/share/poudriere/html/index.html
dist_assets_DATA=	src/share/poudriere/html/assets/poudriere.js \
			src/share/poudriere/html/assets/logo.svg \
			src/share/poudriere/html/assets/favicon.ico \
			src/share/poudriere/html/assets/poudriere.css \
			src/share/poudriere/html/assets/jquery-1.11.0.min.js
dist_btjs_DATA=		src/share/poudriere/html/assets/bootstrap/js/bootstrap.min.js
dist_btfonts_DATA=	src/share/poudriere/html/assets/bootstrap/fonts/glyphicons-halflings-regular.eot \
			src/share/poudriere/html/assets/bootstrap/fonts/glyphicons-halflings-regular.svg \
			src/share/poudriere/html/assets/bootstrap/fonts/glyphicons-halflings-regular.ttf \
			src/share/poudriere/html/assets/bootstrap/fonts/glyphicons-halflings-regular.woff
dist_btcss_DATA=	src/share/poudriere/html/assets/bootstrap/css/bootstrap-theme.min.css \
			src/share/poudriere/html/assets/bootstrap/css/bootstrap.min.css
dist_dtcss_DATA=	src/share/poudriere/html/assets/dataTables/css/jquery.dataTables.min.css
dist_dtjs_DATA=		src/share/poudriere/html/assets/dataTables/js/jquery.dataTables.min.js
dist_dtimages_DATA=	src/share/poudriere/html/assets/dataTables/images/back_disabled.png \
			src/share/poudriere/html/assets/dataTables/images/back_enabled.png \
			src/share/poudriere/html/assets/dataTables/images/back_enabled_hover.png \
			src/share/poudriere/html/assets/dataTables/images/forward_disabled.png \
			src/share/poudriere/html/assets/dataTables/images/forward_enabled.png \
			src/share/poudriere/html/assets/dataTables/images/forward_enabled_hover.png \
			src/share/poudriere/html/assets/dataTables/images/sort_asc.png \
			src/share/poudriere/html/assets/dataTables/images/sort_asc_disabled.png \
			src/share/poudriere/html/assets/dataTables/images/sort_both.png \
			src/share/poudriere/html/assets/dataTables/images/sort_desc.png \
			src/share/poudriere/html/assets/dataTables/images/sort_desc_disabled.png

dist_rc_SCRIPTS=	src/etc/rc.d/poudriered

pkglibexec_PROGRAMS= \
		     cpdup \
		     dirempty \
		     dirwatch \
		     nc \
		     poudriered \
		     rename \
		     timestamp \
		     tsort \
		     jexecd \
		     rexec

noinst_LIBRARIES=	libucl.a libnv.a

AUTOMAKE_OPTIONS=	subdir-objects

rename_SOURCES=	src/libexec/poudriere/rename/rename.c
cpdup_SOURCES=	src/libexec/poudriere/cpdup/cpdup.c \
		src/libexec/poudriere/cpdup/hcproto.c \
		src/libexec/poudriere/cpdup/hclink.c \
		src/libexec/poudriere/cpdup/misc.c \
		src/libexec/poudriere/cpdup/fsmid.c \
		src/libexec/poudriere/cpdup/md5.c
cpdup_LDADD=	-lmd
cpdup_CFLAGS=	-D_ST_FLAGS_PRESENT_=1
dirempty_SOURCES=	src/libexec/poudriere/dirempty/dirempty.c
dirwatch_SOURCES=	src/libexec/poudriere/dirwatch/dirwatch.c
nc_SOURCES=		src/libexec/poudriere/nc/nc.c
timestamp_SOURCES=	src/libexec/poudriere/timestamp/timestamp.c
tsort_SOURCES=		src/libexec/poudriere/tsort/tsort.c
libucl_a_SOURCES=	external/libucl/src/ucl_emitter.c \
			external/libucl/src/ucl_hash.c \
			external/libucl/src/ucl_parser.c \
			external/libucl/src/ucl_util.c \
			external/libucl/src/xxhash.c
libucl_a_CFLAGS=	-I$(top_srcdir)/external/libucl/uthash \
			-I$(top_srcdir)/external/libucl/include  \
			-I$(top_srcdir)/external/libucl/src \
			-Wno-unused-parameter -Wno-pointer-sign
libnv_a_SOURCES=	external/libnv/dnvlist.c \
			external/libnv/msgio.c \
			external/libnv/nvlist.c \
			external/libnv/nvpair.c
poudriered_SOURCES=	src/poudriered/poudriered.c
poudriered_CFLAGS=	-DPREFIX=\"$(prefix)\" \
			-I$(top_srcdir)/external/libucl/include
poudriered_LDADD=	libucl.a \
			-lsbuf \
			-lutil

jexecd_SOURCES=	src/libexec/poudriere/jexecd/jexecd.c
jexecd_CFLAGS=	-I$(top_srcdir)/external/libnv
jexecd_LDADD=	libnv.a \
		-lsbuf \
		-lutil \
		-ljail

rexec_SOURCES=	src/libexec/poudriere/rexec/rexec.c
rexec_CFLAGS=	-I$(top_srcdir)/external/libnv
rexec_LDADD=	libnv.a

.PHONY:	gen-make-wiki
gen-man-wiki:
	@if ! which mandoc 2>&1 >/dev/null; then \
	  echo "Mandoc required, install textproc/mdocml"; \
	  exit 1; \
	fi
	@for man in $(dist_man_MANS); do \
	  echo "MANDOC doc/$${man##*/}.wiki"; \
	  ( \
	    echo "<nowiki>"; \
	    (mandoc -Thtml $${man} | awk \
	    '$$1 == "<body>" { seenbody=1; next; }; \
	     $$1 == "</body>" { seenbody=0; }; \
	     seenbody == 1 { print };'\
	    ); \
	    echo "</nowiki>"; \
	  ) > doc/$${man##*/}.wiki; \
	done
