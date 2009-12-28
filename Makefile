HPROGS = hbal hscan hail hspace
HALLPROGS = $(HPROGS) test
HSRCS := $(wildcard Ganeti/HTools/*.hs) $(wildcard Ganeti/*.hs)
HDDIR = apidoc

DOCS = README.html NEWS.html

HFLAGS = -O2 -Wall -Werror -fwarn-monomorphism-restriction -fwarn-tabs
HEXTRA =

HPCEXCL = --exclude Main --exclude Ganeti.HTools.QC

# Haskell rules

all: $(HPROGS)

$(HALLPROGS): %: %.hs Ganeti/HTools/Version.hs $(HSRCS) Makefile
	ghc --make $(HFLAGS) $(HEXTRA) $@

test: HEXTRA=-fhpc -Wwarn

$(DOCS) : %.html : %
	rst2html $< $@

doc: $(DOCS) Ganeti/HTools/Version.hs
	rm -rf $(HDDIR)/*
	mkdir -p $(HDDIR)/Ganeti/HTools
	cp hscolour.css $(HDDIR)/Ganeti/HTools
	for file in $(HSRCS); do \
		HsColour -css -anchor \
		$$file > $(HDDIR)/Ganeti/HTools/`basename $$file .hs`.html ; \
	done
	haddock --odir $(HDDIR) --html --ignore-all-exports \
		-t ganeti-htools -p haddock-prologue \
		--source-module="%{MODULE/.//}.html" \
		--source-entity="%{MODULE/.//}.html#%{NAME}" \
		$(filter-out Ganeti/HTools/ExtLoader.hs,$(HSRCS))

maintainer-clean:
	rm -rf $(HDDIR)
	rm -f $(DOCS) TAGS version Ganeti/HTools/Version.hs

clean:
	rm -f $(HALLPROGS)
	rm -f *.o *.prof *.ps *.stat *.aux *.hi
	rm -f Ganeti/HTools/Version.hs
	cd Ganeti && rm -f *.o *.prof *.ps *.stat *.aux *.hi
	cd Ganeti/HTools && rm -f *.o *.prof *.ps *.stat *.aux *.hi

regen-version:
	rm -f version
	$(MAKE) version

version:
	if test -d .git; then \
	  git describe > $@; \
	elif test ! -f $@ ; then \
	  echo "Cannot auto-generate $@ file"; exit 1; \
	fi

Ganeti/HTools/Version.hs: Ganeti/HTools/Version.hs.in version
	sed -e "s/%ver%/$$(cat version)/" < $< > $@

dist: regen-version Ganeti/HTools/Version.hs doc
	set -e ; \
	VN=$$(cat version|sed 's/^v//') ; \
	PFX="ganeti-htools-$$VN" ; \
	ANAME="$$PFX.tar" ; \
	rm -f $$ANAME $$ANAME.gz ; \
	git archive --format=tar --prefix=$$PFX/ HEAD > $$ANAME ; \
	tar -r -f $$ANAME --owner root --group root \
	    --transform="s,^,$$PFX/," version apidoc $(DOCS) ; \
	gzip -v9 $$ANAME ; \
	TMPDIR=$$(mktemp -d) ; \
	tar xzf $$ANAME.gz -C $$TMPDIR; \
	(cd $$TMPDIR/$$PFX; make; make clean; make check); \
	rm -rf $$TMPDIR ; \
	tar tzvf $$ANAME.gz ; \
	sha1sum $$ANAME.gz ; \
	echo "Archive $$ANAME.gz created."

check: test
	rm -f *.tix *.mix
	./test
ifeq ($(T),markup)
	mkdir -p coverage
	hpc markup --destdir=coverage test $(HPCEXCL)
else
	hpc report test $(HPCEXCL)
endif

tags:
	find -name '*.hs' | xargs hasktags -e

.PHONY : all doc maintainer-clean clean dist check tags regen-version
