PACKAGE_VERSION := $(shell dpkg-parsechangelog -SVersion -l../debian/changelog)

CPPFLAGS ?=
CPPFLAGS += -DPACKAGE_VERSION="\"$(PACKAGE_VERSION)\""

CFLAGS ?= -ggdb -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS += -fPIC -ldl -fvisibility=hidden

PLUGIN = fake-uname.so

$(PLUGIN): fake-uname.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ -shared $<

UNAME_CHECK = LD_PRELOAD="$(CURDIR)/$(PLUGIN)" uname

check: $(PLUGIN)
	test "0.0.0" = "$(shell $(UNAME_CHECK) -r)"
	test "1.2.3" = "$(shell UTS_RELEASE="1.2.3" $(UNAME_CHECK) -r)"

clean:
	$(RM) *.o *.so
