PACKAGE_VERSION := $(shell dpkg-parsechangelog -SVersion -l../debian/changelog)

CPPFLAGS ?=
CPPFLAGS += -DPACKAGE_VERSION="\"$(PACKAGE_VERSION)\""

CFLAGS ?= -ggdb -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS += -fPIC -ldl

PLUGIN = fake-uname.so

$(PLUGIN): fake-uname.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ -shared $<

clean:
	$(RM) *.o *.so
