#!/usr/bin/perl
# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id$

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
# NOTICE!
#
# This is a very, very simple script.  Simplistic, really.  Stupid, nearly.
#
# rtilder    Mon Apr 25 14:31:35 PDT 2005
#


use strict;
use CGI;
use IO::Dir;
use Storable qw(nfreeze);

#my $REPOURL = 'http://repository/spine/';
my $REPOURL = "http://$ENV{HTTP_HOST}/spine-configballs/";
#my $SRCDIR  = '/fls1/vol1/websys-config-repo';
my $SRCDIR  = '/ops/shared/htdocs/spine-configballs';
#my $DEFAULT = 'websys';
my $DEFAULT = '';
my $FILENAME_RE = 'spine-config-?(.*)?-(\d+).(iso\.gz|cramfs)$';

#
# Valid parameter names for this CGI:
#
# [Required]
#
#   "a"        The type of action to perform.  Valid values are currently:
#
#              "check"   See if there are any newer releases of the configball
#              "gimme"   Redirect to the location of the named configball.
#
#   "prev"     Required for the "a=check" action.  May be null.
#
#   "release"  Required for the "a=gimme" action.
#
# [Optional]
#
#   "branch"   The name of the configball branch to check for.
#
#
#


sub get_branch_releases
{
    my $src = shift;
    my %rc  = ();
    my $d = new IO::Dir($src);

    if (not defined($d)) {
        print STDERR "Failed to open $src: $!\n";
        return undef;
    }

    while (defined(my $entry = $d->read())) {
        # Ignore certain basic patterns
        if ($entry =~ m/^\./
            or $entry =~ m/~$/
            or $entry =~ m/^\#/) {
            next;
        }

        if ($entry =~ m/$FILENAME_RE/) {
            # $1, if it exists, is the branch name
            # $2 is the release number
            # $3 is the file extension
            $rc{$2} = { filename => $entry,
                        path     => $src,
                        branch   => $1,
                        release  => $2,
                        type => lc($3) == 'cramfs' ? 'cramfs' : 'isofs' };
        }
    }

    if (scalar(keys(%rc)) == 0) {
        return undef;
    }

    return wantarray ? %rc : \%rc;
}


my $q = new CGI;
my ($action, $prev, $release, $branch);


#
# First some parameter validation
#
$action = $q->param('a');
if (not defined($action)) {
    print $q->header(-type => 'text/html',
                     -status => '500 Need to specify an action');
    goto buhbye;
}

if ($action eq 'check') {
    $prev = $q->param('prev');

    if (not defined($prev)) {
        print $q->header(-type => 'text/html',
                         -status => '500 Need to specify a previous revision');
        goto buhbye;
    }
}
elsif($action eq 'gimme') {
    $release = $q->param('release');

    if (not defined($release)) {
        print $q->header(-type => 'text/html',
                         -status => '500 Need to specify a release to grab');
        goto buhbye;
    }
}
else {
    print $q->header(-type => 'text/html',
                     -status => '500 Need to specify action type');
    goto buhbye;
}


# If we got a branch name, look in that branch's subdirectory
$branch = $q->param('branch');

if (not defined($branch)) {
    $branch = $DEFAULT;
}

$SRCDIR .= "/$branch";

if (not -d $SRCDIR) {
    print $q->header(-type => 'text/html',
                     -status => "500 Invalid branch: \"$branch\"");
    goto buhbye;
}


# Walk the directory tree and build a list of available releases
my $releases = get_branch_releases($SRCDIR);

if (not defined($releases)) {
    print $q->header(-type => 'text/html',
                     -status => "404 No releases found for branch: \"$branch\"");
    goto buhbye;
}


# Is someone checking revisions?
if ($action eq 'check') {
    my @a = sort {$a <=> $b} (keys(%{$releases}));
    my $latest = pop(@a);
    my %hash = ( latest_release => $latest );
    my $payload = nfreeze(\%hash);

    # Build the response
    print $q->header(-type => 'application/perl-storable',
                     -content_length => length($payload));
    print $payload;
}
elsif ($action eq 'gimme') {
    if (not exists($releases->{$release})) {
        print $q->header(-type => 'text/html',
                         -status => "404 No release number \"$release\" for branch \"$branch\"");
        goto buhbye;
    }

    print $q->redirect("$REPOURL/$branch/" . $releases->{$release}->{filename});
}

buhbye:
exit(0);
