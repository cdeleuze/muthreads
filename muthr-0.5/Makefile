# Application level concurrency in OCaml - Muthreads

OCAMLC=ocamlc
OCAMLOPT=ocamlopt

# where to install
LIBDIR=/usr/local/lib/ocaml

.PHONY: all install clean htmldoc

all: clean muthr muthr_retry muthr_misc

install:
	cp muthr.cma muthr.cmi muthr_retry.cma muthr_retry.cmi muthr_misc.cma muthr_misc.cmi $(LIBDIR)
	cp muthr.a muthr.cmxa muthr_retry.a muthr_retry.cmxa muthr_misc.a muthr_misc.cmxa $(LIBDIR)

clean:
	rm -f *.cmo *.cmi *.cma *.cmx *.cmxa *.a *.o *.dvi *.ps *.log *.aux

htmldoc: muthr.mli muthr_retry.mli
	ocamldoc -html -d ../HtmlDoc $^

dvidoc : muthr.dvi muthr_retry.dvi

muthr.dvi: muthr.mli
	ocamldoc -latex -o muthr.tex $<
	latex muthr
	rm -f muthr.tex muthr.toc muthr.aux

muthr_retry.dvi: muthr_retry.mli
	ocamldoc -latex -o muthr_retry.tex $<
	latex muthr_retry
	rm -f muthr_retry.tex muthr_retry.toc muthr_retry.aux

%.ps : %.dvi
	dvips $<

.PHONY: muthr muthr_retry muthr_misc
muthr: muthr.cmi muthr.cma muthr.cmxa
muthr_retry: muthr_retry.cmi muthr_retry.cma muthr_retry.cmxa
muthr_misc: muthr_misc.cmi muthr_misc.cma muthr_misc.cmxa

%.cmo : %.ml %.cmi
	$(OCAMLC) -c $<

%.cmo : %.ml
	$(OCAMLC) -c $<

%.cmi : %.mli
	$(OCAMLC) -c $< 

%.cmx : %.ml %.cmi
	$(OCAMLOPT) -c $<

%.cma : %.cmo %.cmi
	$(OCAMLC) -a $< -o $@

%.cmxa : %.cmx %.cmi
	$(OCAMLOPT) -a $< -o $@
