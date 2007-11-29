# $Id: spine.spec,v 1.2.2.23.2.3.2.4 2007/11/19 21:53:39 phil Exp $
# vim:ts=8:noet

%define spine_ver		2.0
%define spine_rel		rc22
%define spine_prefix		/usr
%define spine_lib_prefix	%{spine_prefix}/lib/spine
%define File_Temp_ver		0.16
%define Sys_Syslog_ver          0.18

Name:      spine
Summary:   Ticketmaster Configuration System
Version:   %{spine_ver}
Release:   %{spine_rel}
Vendor:    Ticketmaster
License:   GPLv3
Group:     System/Libraries
Source:    %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-root
BuildArch: noarch
Requires:  dialog >= 0.9
Requires:  lshw >= 2.11
Requires:  perl(Digest::MD5) >= 2.20
Requires:  perl(Net::DNS) >= 0.49
Requires:  perl(Template) >= 2.14
Requires:  perl(Text::Diff) >= 0.35
Requires:  perl(NetAddr::IP) >= 3.24
Requires:  perl(File::Touch) >= 0.01
Requires:  perl(File::Temp) >= 0.14
Requires:  perl(YAML::Syck)
Requires:  perl(JSON::Syck)
Requires:  perl(XML::Simple) >= 2.12
# Provided by ourself, currently.
Requires:  perl(File::Temp) >= %{File_Temp_ver}
Requires:  perl(Sys::Syslog) >= %{Sys_Syslog_ver}

%description
Ticketmaster Configuration System

%ifarch noarch
%package fsball-publisher
Summary:   Ticketmaster configuration system's publishing system
Group:     Ticketmaster
BuildArch: noarch
Requires:  python >= 2.2.3-5

%description fsball-publisher
Ticketmaster configuration system's publishing system
%endif

%prep
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT

%setup -c -a 0 -n %{name}

%install
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT

cd %{name}-%{version}
# Hooray for Makefiles!
make DESTDIR=$RPM_BUILD_ROOT install


# Shortcut the install of File::Temp
%{__mkdir_p} -m 755 $RPM_BUILD_ROOT%{spine_lib_prefix}/File

%clean
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
%attr(0755,root,root) %{spine_prefix}/bin/ui
%attr(0755,root,root) %{spine_prefix}/bin/spine
%attr(0755,root,root) %{spine_prefix}/bin/quick_template
%dir %{spine_lib_prefix}
%dir %{spine_lib_prefix}/Spine
%dir %{spine_lib_prefix}/Spine/ConfigSource
%dir %{spine_lib_prefix}/Spine/Plugin
%{spine_lib_prefix}/Spine/*.pm
%{spine_lib_prefix}/Spine/ConfigSource/*.pm
%{spine_lib_prefix}/Spine/Plugin/*.pm
%config(noreplace) /etc/spine.conf
#
# This makes RPM 4.4 angry
#
#%{_localstatedir}/spine
%attr(0755,root,root) %{_localstatedir}/spine

%ifarch noarch
%files fsball-publisher
%defattr(-,root,root)
%{spine_prefix}/bin/spine-cramfs-publish.py
%{spine_prefix}/bin/spine-cramfs-publish.pyo
%{spine_prefix}/bin/spine-cramfs-publish.pyc
%config(noreplace) /etc/cramfs-publisher.conf

%endif

%changelog
* Wed Oct 03 2007 Phil Dibowitz <phil.dibowitz@ticketmaster.com> 2.0-rc22
- Add support for parsing lshw output
- Add --action and --actiongroup support

* Wed Oct 03 2007 Phil Dibowitz <phil.dibowitz@ticketmaster.com> 2.0-rc21
- Merge many pieces of what was supposed to be in rc20 from the old 2.0 branch
  into this branch so this will actually work.

* Wed Oct 03 2007 Phil Dibowitz <phil.dibowitz@ticketmaster.com> 2.0-rc20
- Hostname parsing abstraction
- Descend order abstraction

* Wed Aug 09 2007 Phil Dibowitz <phil.dibowitz@ticketmaster.com> 2.0-rc19
- Merging spine-thinks-undef-and-0-are-the-same fix into 2.x

* Wed Aug 08 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc18
- The is_virtual() method didn't work quite as it should on non-virtual
  hardware.

* Wed Aug 01 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc17
- The is_virtual() call to /sbin/lspci requires the -n switch for the regexp
  for the VMWare PCI vendor and device IDs to work.

* Wed Aug 01 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc16
- Fix stupid typo in previous checking

* Fri Jul 27 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc15
- Fix a really, really stupid auth bug that was manifesting only on the EDBs
- Import the 1.6.8 changes to provide AS5/CentOS5 support
- Pull in Phil's Spine::Data::auth::_sanity_check_user_map() fix from 1.6.7-3

* Thu Jul 05 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc14
- Increment the release number because I made a booboo with rc13

* Thu Jul 05 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc13
- Quick fix to the descend order plugin to revert the change I apparently made
  to dependency resolution so that it would do breadth first rather than depth
  first.  Weird that I would do that.

* Wed Jun 06 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc11
- Apparently there's been a problem with certain PXY boxes and their /media 
  mount points causing rsync errors with apply_overlay that have popping up for
  quite some time.  It isn't a true fatal error, so provide some override
  ability.

* Fri Jun 01 2007 Phil Dibowitz <phil@ticketmaster.com> 2.0-rc10
- Fix spec file requirement of YAML::JSON -> JSON::Syck
- Better auth module description
- Remove duplicate definition of $VERSION in auth.pm

* Fri Jun 01 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc9
- Looks like most of the merge between 1.6.x and 2.0 should be complete but
  definitely needs more testing.

* Wed May 08 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc8
- Fix some gross oversights from the earlier variable change in rc7.

* Fri Apr 20 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc7
- Tweak Spine::Registry::load_plugin() to require all plugins be under the
  Spine::Plugin:: namespace.  See 
  http://bugzilla.websys.tmcs/show_bug.cgi?id=35114
- Fix Spine::Plugin::Templates::quick_template() to only return PLUGIN_EXIT,
  even when there's an error processing the template.  See
  http://bugzilla.websys.tmcs/show_bug.cgi?id=35115
- Change a few important top level variable declarations to facilitate access
  to them by any plugins that are silly enough to want to.

* Thu Jan 11 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc6
- Spine::Plugin::Finalize and Spine::Plugin::RestartServices needed to have
  their return values massaged.  Looks like I missed them in the mass
  conversion I did earlier.
- Looks like we can't pass the INTERPOLATE option to Template Toolkit.  It
  blows up all angry like when it processes things like a bashrc.
- Fix the Template processing error checking and reporting

* Thu Jan 11 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc5
- Merge the latest 1.6.4 plugin changes from HEAD
- Have Spine::Plugin::Templates::process_template() only ever instantiate
  one Template object per run.  We don't need more than one.

* Mon Jan 08 2007 Ryan Tilder <ryan.tilder@ticketmaster.com> 2.0-rc1
- Initial 2.0 series release candidate
- Whoops!  Replace quick_template as quick_template

