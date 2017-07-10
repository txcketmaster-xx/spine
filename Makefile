# $Id$
# vim:ts=8:sw=8:noet

#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# (C) Copyright Ticketmaster, Inc. 2007
#

DESTDIR  ?= 
PREFIX   ?= /usr
ETCDIR   ?= /etc/spine-mgmt
INITDIR  ?= /etc/init.d
BINDIR   ?= $(PREFIX)/bin
LIBDIR   ?= $(PREFIX)/lib/spine-mgmt
STATEDIR ?= /var/spine-mgmt
BALLDIR  ?= $(STATEDIR)/configballs
SUBDIRS   = $(ETCDIR) $(INITDIR) $(STATEDIR) $(BALLDIR) $(BINDIR) $(LIBDIR)
MKDIR    ?= /bin/mkdir
INSTALL  ?= /usr/bin/install

all:

mkdirs:
	for dir in $(SUBDIRS); do \
		$(MKDIR) -p -m 0755 $(DESTDIR)$$dir; \
	done

install_config: spine-mgmt.conf publisher/spine-publisher.conf.dist
	for I in $^; do \
		dest=`echo $$I | sed -e 's:publisher/::' -e 's:\.dist::'`; \
		$(INSTALL) -m 0644 $$I $(DESTDIR)$(ETCDIR)/$$dest; \
	done


install_scripts: spine-mgmt quick_template ui publisher/spine-publisher getvals
	for I in $^; do \
		$(INSTALL) -m 0755 $$I $(DESTDIR)$(BINDIR); \
	done

install_init: publisher/spine-publisher.init
	dest=`echo $^ | sed -e 's:\.init::' -e 's:publisher/::'`; \
	$(INSTALL) -m 0755 $$I $^ $(DESTDIR)$(INITDIR)/$$dest; \

install_lib:
	cd lib && \
	for module in `find Spine -type f -name \*.pm \( ! -path '*/Data/*' -a ! -path '*/Action/*' \)`; do \
		$(INSTALL) -m 0755 -D $$module $(DESTDIR)$(LIBDIR)/$$module; \
	done \
	&& cd ..

install: mkdirs install_lib install_scripts install_config install_init

.PHONY : all install_lib install_scripts install_init install_config
