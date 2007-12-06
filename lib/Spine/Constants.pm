# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Constants.pm,v 1.1.2.7.2.3 2007/09/13 16:15:15 rtilder Exp $

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

use strict;

package Spine::Constants;
use Spine::Exception;
use base qw(Exporter);

our ($VERSION, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.7.2.3 $ =~ /(\d+)\.(\d+)/);

my $tmp;

use constant {
    SPINE_NOTRUN  => -1,
    SPINE_FAILURE => 0,
    SPINE_SUCCESS => 1
};

#use Spine::Exception::Exit qw(SpineExit);
use Spine::Exception qw(SpineExit);

$tmp = [qw(SPINE_NOTRUN SPINE_FAILURE SPINE_SUCCESS SpineExit)];
push @EXPORT_OK, @{$tmp};
$EXPORT_TAGS{basic} = $tmp;

$tmp = undef;

#
# For plugins, we define two simple constants and two exception classes
#
use constant {
    PLUGIN_ERROR   => SPINE_FAILURE,
    PLUGIN_SUCCESS => SPINE_SUCCESS
};

#use Spine::Exception::Exit qw(PluginFatal);
use Spine::Exception qw(PluginFatal);

$tmp = [qw(PLUGIN_ERROR PLUGIN_SUCCESS PluginFatal)];
push @EXPORT_OK, @{$tmp};
$EXPORT_TAGS{plugin} = $tmp;

$tmp = undef;

#
# Constants for the chain of responsibility return values
#

use constant {
    PARSE_STOP => 1 << 0,
    PARSE_MODIFIED => 1 << 1,
    PARSE_HANDLED  => 1 << 2,
};

use constant NOT_IMPLEMENTED => \"Ain't no sich animal.";

use Spine::Exception qw(SyntaxError);

$tmp = [qw(PARSE_STOP PARSE_MODIFIED PARSE_HANDLED NOT_IMPLEMENTED
           SyntaxError)];
push @EXPORT_OK, @{$tmp};
$EXPORT_TAGS{parse} = $tmp;

$tmp = undef;


#
# Constants for the publisher
#

# Needs to match the Subversion's svn_node_kind_t enum as documented in
# svn_types.h
use constant {
    SVN_ABSENT    => 0,
    SVN_FILE      => 1,
    SVN_DIRECTORY => 2,
    SVN_UNKNOWN   => 3
};

# Used for testing the values of the spine:filetype property
use constant {
    RBX_FILETYPE_BLOCK => 'block',
    RBX_FILETYPE_CHAR  => 'character',
    RBX_FILETYPE_PIPE  => 'fifo'
};

use constant {
    RBX_TYPE_NULL  =>  1,
    RBX_TYPE_KEY   =>  2,
    RBX_TYPE_BLOCK =>  3,
    RBX_TYPE_CHAR  =>  4,
    RBX_TYPE_FILE  =>  5,
    RBX_TYPE_DIR   =>  6,
    RBX_TYPE_LINK  =>  7,
    RBX_TYPE_PIPE  =>  8,
    RBX_TYPE_TMPL  =>  9,
    RBX_TYPE_UNIX  => 10,
};

$tmp = [qw(SVN_ABSENT SVN_FILE SVN_DIRECTORY SVN_UNKNOWN
           RBX_FILETYPE_BLOCK RBX_FILETYPE_CHAR RBX_FILETYPE_PIPE
           RBX_TYPE_KEY RBX_TYPE_BLOCK RBX_TYPE_CHAR RBX_TYPE_FILE
           RBX_TYPE_DIR RBX_TYPE_LINK RBX_TYPE_PIPE RBX_TYPE_TMPL
           RBX_TYPE_UNIX)];
push @EXPORT_OK, @{$tmp};
$EXPORT_TAGS{publish} = $tmp;

$tmp = undef;


use constant MIME_TYPE_PREFIX    => 'application/vnd.rbx.';
use constant MIME_TYPE_FS_PREFIX => MIME_TYPE_PREFIX . 'fs.';

use constant {
    MIME_TYPE_NULL  => MIME_TYPE_PREFIX    . 'null',
    MIME_TYPE_KEY   => MIME_TYPE_PREFIX    . 'key',
    MIME_TYPE_BLOCK => MIME_TYPE_FS_PREFIX . 'block',
    MIME_TYPE_CHAR  => MIME_TYPE_FS_PREFIX . 'character',
    MIME_TYPE_FILE  => MIME_TYPE_FS_PREFIX . 'file',
    MIME_TYPE_DIR   => MIME_TYPE_FS_PREFIX . 'directory',
    MIME_TYPE_LINK  => MIME_TYPE_FS_PREFIX . 'symlink',
    MIME_TYPE_PIPE  => MIME_TYPE_FS_PREFIX . 'pipe',
    MIME_TYPE_TMPL  => MIME_TYPE_FS_PREFIX . 'template',
    MIME_TYPE_UNIX  => MIME_TYPE_FS_PREFIX . 'socket'
};

# Indexed to how it
our $TYPE_MAP = [
    undef,
    MIME_TYPE_NULL, MIME_TYPE_KEY, MIME_TYPE_BLOCK, MIME_TYPE_CHAR,
    MIME_TYPE_FILE, MIME_TYPE_DIR, MIME_TYPE_LINK, MIME_TYPE_PIPE,
    MIME_TYPE_TMPL, MIME_TYPE_UNIX
];

$tmp = [qw(MIME_TYPE_BLOCK MIME_TYPE_CHAR MIME_TYPE_FILE MIME_TYPE_DIR
           MIME_TYPE_LINK MIME_TYPE_PIPE MIME_TYPE_TMPL MIME_TYPE_UNIX
           MIME_TYPE_NULL MIME_TYPE_KEY $TYPE_MAP)];
push @EXPORT_OK, @{$tmp};
$EXPORT_TAGS{mime} = $tmp;


1;
