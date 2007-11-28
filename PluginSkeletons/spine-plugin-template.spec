# $Id: spine-plugin-template.spec,v 1.1.18.1 2007/10/02 22:01:26 phil Exp $

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

#
# Skeleton specfile for spine plugins
#
# I haven't actually tested this yet but it'll likely work 
#

# Parent spine packages
%define spine_ver		1.7
%define spine_rel		rc2
%define spine_lib_prefix	%{spine_prefix}/lib/spine

# tmbuild variables
%define tm_srcpath		/bld/shared/source/spine
%define tm_devtag		HEAD
%define tm_modules		syseng/spine
%define tm_skiptag		1

# Plugin specific variables
%define plugin_name		%{nil}
%define plugin_ver		%{nil}
%define plugin_rel		%{nil}
# These two should just be whitespace separated lists of filenames relative to
# the syseng/spine/ tree.
%define plugin_actions		%{nil}
%define plugin_data_plugins	%{nil}
%define plugin_config_sources	%{nil}

Name:      spine-plugin-%{plugin_name}
Summary:   %{plugin_name} plugin for the Spine configuration system
Version:   %{plugin_ver}
Release:   %{plugin_rel}
Vendor:    Ticketmaster Systems Engineering
License:   Restricted Distribution
Group:     System/Libraries
Source:    spine-%{spine_ver}-cvs.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-root
Requires:  spine >= %{spine_ver}-%{spine_rel}
# Insert any additional perl requirements here
#Requires:  perl(File::Temp) >= 0.14

%description
%{plugin_name} plugin for the Spine configuration system

%prep
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT

%setup -c -a 0 -a 3 -n %{name}

%build
:

%install
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT

pushd syseng
%{__mkdir_p} -m 755 $RPM_BUILD_ROOT%{spine_lib_prefix}

# Actions, delete this conditional and loop if you're not providing
if [ "%{plugin_actions}" ]; do
	%{__mkdir_p} -m 755 $RPM_BUILD_ROOT%{spine_lib_prefix}/Spine/Action
	for I in %{plugin_actions}; do
		%{__install} -m 0644 ${I} $RPM_BUILD_ROOT%{spine_lib_prefix}/Spine/Action
	done
fi

# Data plugins, delete this conditional and loop if you're not providing
if [ "%{plugin_data_plugins}" ]; do
	%{__mkdir_p} -m 755 $RPM_BUILD_ROOT%{spine_lib_prefix}/Spine/Data
	for I in %{plugin_data_plugins}; do
		%{__install} -m 0644 ${I} $RPM_BUILD_ROOT%{spine_lib_prefix}/Spine/Data
	done
fi

# ConfigSource plugins, delete this conditional and loop if you're not providing
if [ "%{plugin_config_sources}" ]; do
	%{__mkdir_p} -m 755 $RPM_BUILD_ROOT%{spine_lib_prefix}/Spine/ConfigSource
	for I in %{plugin_config_sources}; do
		%{__install} -m 0644 ${I} $RPM_BUILD_ROOT%{spine_lib_prefix}/Spine/ConfigSource
	done
fi

popd

# A little paranoia left over from the original Spine specfile and totally
# superfluous
find $RPM_BUILD_ROOT -name CVS -type d | xargs rm -rf

%clean
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT

%files
%if %{plugin_actions} != %{nil}
%{spine_lib_prefix}/Spine/Action/*.pm
%endif
%if %{plugin_data_plugins} != %{nil}
%{spine_lib_prefix}/Spine/Data/*.pm
%endif
%if %{plugin_config_sources} != %{nil}
%{spine_lib_prefix}/Spine/ConfigSource/*.pm
%endif

%changelog
* Mon Jun  5 2005 Ryan Tilder <rtilder@ticketmaster.com> 0.0
- Initial skeletal plugin specfile

