PACKAGE_VERSION := $(shell dpkg-parsechangelog -SVersion -l../debian/changelog)

CPPFLAGS ?=
CPPFLAGS += -DPACKAGE_VERSION="\"$(PACKAGE_VERSION)\""

CFLAGS = -ggdb -O2 -Wall -Wextra -Wno-unused-parameter -fPIC -ldl
CFLAGS += -D_GNU_SOURCE

PLUGIN = fake_uname.so

$(PLUGIN): fake_uname.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ -shared $<

clean:
	$(RM) *.o *.so
