# -*- mode: cperl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
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

package Spine::Data;

use strict;

use Cwd;
use Data::Dumper;
use File::Basename;
use File::Spec::Functions;
use IO::File;
use Spine::Constants qw(:basic);
use Spine::Registry;
use Spine::Util;
use Sys::Syslog;
use UNIVERSAL;

use YAML::Syck;
use JSON::Syck;

our $DEBUG = $ENV{SPINE_DATA_DEBUG} || 0;

my ($DATA_PARSED, $DATA_POPULATED) = (SPINE_NOTRUN, SPINE_NOTRUN);

our $VERSION = sprintf("%d.%02d", q$Revision$ =~ /(\d+)\.(\d+)/);

sub new {
    my $class = shift;
    my %args = @_;

    my $registry = new Spine::Registry();
    my $croot = $args{croot} || $args{source}->config_root() || undef;

    unless ($croot) {
        die "No configuration root passed to Spine::Data!  Badness!";
    }

    my $data_object = bless( { hostname => $args{hostname},
                               c_release => $args{release},
                               c_verbosity => $args{verbosity} || 0,
                               c_version => $args{version} || $::VERSION,
                               c_config => $args{config},
                               c_croot => $croot,
                             }, $class );

    if (not defined($data_object->{c_release}))
    {
        print STDERR "Spine::Data::new(): we require the config release number!";
        return undef;
    }

    # Let's register the hookable points we're going to be running

    # Runtime data discovery.  Basically these are keys that will show up in
    # $c(a.k.a. the "c" object in a template) that aren't parsed out of the
    # configball.  This is stuff like c_is_virtual, c_filer_exports, etc.
    $registry->create_hook_point(qw(DISCOVERY/populate
                                    DISCOVERY/policy-selection));

    # The actual parsing of the configball
    $registry->create_hook_point(qw(PARSE/initialize
                                    PARSE/pre-descent
                                    PARSE/post-descent
                                    PARSE/complete));

    # XXX Right now, the driver script handles error reporting
    $data_object->_data();

    return $data_object;
}


sub _data
{
    my $self = shift;
    my $rc = SPINE_SUCCESS;

    my $cwd = getcwd();
    chdir($self->{c_croot});

    unless ($self->populate() == SPINE_SUCCESS) {
        $self->{c_failure} = 'Failure to populate: ' . $self->{c_failure};
        $rc = SPINE_FAILURE;
    }

    unless ($rc == SPINE_SUCCESS and $self->parse() == SPINE_SUCCESS) {
        $self->{c_failure} = 'Failure to parse: ' . $self->{c_failure};
        $rc = SPINE_FAILURE;
    }

    return $rc;
}


sub populate
{
    my $self = shift;
    my $registry = new Spine::Registry();
    my $errors = 0;

    if ($DATA_POPULATED != SPINE_NOTRUN) {
        return $DATA_POPULATED;
    }

    # Some truly basic stuff first.
    $self->{c_label} = 'spine_core';
    $self->{c_start_time} = time();
    $self->{c_ppid} = $$;

    # FIXME  Should these be moved to Spine::Plugin::Overlay?
    $self->{c_tmpdir} = "/tmp/spine." . $self->{c_ppid};
    $self->{c_tmplink} = "/tmp/spine.lastrun";

    #
    # Begin discovery
    #

    # Retrieve 'local' config values nesessary for parsing
    # the hierarchy itself.
    $self->cprint("retrieving local settings", 3);
    $self->{c_local_dir} = "$self->{c_croot}/local";
    $self->_get_values($self->{c_local_dir});

    # HOOKME  Discovery: populate
    my $point = $registry->get_hook_point('DISCOVERY/populate');

    my $rc = $point->run_hooks($self);

    # Spine::Registry::HookPoint::run_hooks() returns the number of
    # errors + failures encountered by plugins
    if ($rc != 0) {
        $DATA_POPULATED = SPINE_FAILURE;
        $self->{c_failure} = "DISCOVERY/populate failed!";
        return SPINE_FAILURE;
    }

    # Parse the hostname and verify the format is acceptable.
    # An invalid hostname means we cannot continue.

    # Call _get_sysinfo which returns various information gathered
    # from the system.

    # Call _get_netinfo which loops through the networks defined
    # in the networks hierarchy.  If our IP address fits into
    # one of the defined subnets, we return associated data.

    # We do not have a valid subnet and cannot continue.

    # HOOKME  Discovery: policy selection
    #
    # Using the data we have gathered, construct the directory paths for
    # our hierarchy.
    #

    # Run our policy selection hooks
    $point = $registry->get_hook_point('DISCOVERY/policy-selection');

    $rc = $point->run_hooks($self);

    unless ($rc == 0) {
        $DATA_POPULATED = SPINE_FAILURE;
        $self->{c_failure} = "DISCOVERY/policy-selection failed!";
        return SPINE_FAILURE;
    }

    $DATA_POPULATED = SPINE_SUCCESS;

    return SPINE_SUCCESS;
}


sub parse
{
    my $self = shift;
    my $registry = new Spine::Registry();
    my $errors = 0;

    if ($DATA_PARSED != SPINE_NOTRUN) {
        return $DATA_PARSED;
    }

    # Make sure our discovery phases has been run first since we need a bunch
    # of that info for out parsing.  Most notably the descend order.
    unless ($self->populate() == SPINE_SUCCESS) {
        $self->{c_failure} = "Can't parse, runtime discovery failed somehow!";
        goto parse_failure;
    }

    #
    # Begin parse
    #

    # HOOKME  Parse: parse initialize
    my $point = $registry->get_hook_point('PARSE/initialize');

    my $rc = $point->run_hooks($self);

    if ($rc != 0) {
        $self->{c_failure} = "PARSE/initialize failed!";
        goto parse_failure;
    }

    # Gather config data from the entire hierarchy.
    $self->cprint('descending hierarchy', 3);
    foreach my $branch (@{$self->{c_hierarchy}})
    {
        # HOOKME  Parse: pre-policy descent
        $point = $registry->get_hook_point('PARSE/pre-descent');

        $rc = $point->run_hooks($self);

        if ($rc != 0) {
            $self->{c_failure} = "Failed to run at least one PARSE/pre-descent hook";
            goto parse_failure;
        }

        if (not $self->get_configdir($branch)) {
            return 0;
        }

        # HOOKME  Parse: post-policy descent
        $point = $registry->get_hook_point('PARSE/post-descent');

        $rc = $point->run_hooks($self);

        if ($rc != 0) {
            $self->{c_failure} = "Failed to run at least one PARSE/post-descent hook";
            goto parse_failure;
        }

    }

    # HOOKME  Parse: parse complete
    $point = $registry->get_hook_point('PARSE/complete');

    $rc = $point->run_hooks($self);

    if ($rc != 0) {
        $self->{c_failure} = "Failed to run at least one PARSE/complete hook";
        goto parse_failure;
    }

    $self->cprint("parse complete", 1);

    return SPINE_SUCCESS;

 parse_failure:
    $DATA_PARSED = SPINE_FAILURE;
    return SPINE_FAILURE;
}


#
# FIXME  Used only by plugins, pretty much
#
sub set_label
{
    my $self = shift;
    my $label = shift;

    if ($label)
    {
	$self->{c_label} = $label;
	return 1;
    }

    return 0;
}


sub check_exec
{
    my $self = shift;
    foreach my $binary (@_)
    {
	return 0 unless (defined $binary);
	$self->cprint("checking binary $binary", 4);
	if ( ! -x "$binary" )
	{
	    $self->error("binary $binary is unavailable: $!", "crit");
	    return 0;
 	}
    }
    return 1;
}


sub util
{
    my $self = shift;
    my $util = shift;

    no strict 'refs';
    my $return = &{"Spine::Util::" . $util}(@_);
    use strict 'refs';
    if (not defined $return)
    {
        my $pargs = join(" ", @_);
	$self->error("$util failed to execute with args: $pargs", 'crit');
    }
    return $return;
}


sub cprint
{
    my $self = shift;
    my ($msg, $level) = @_;
    my $log_to_syslog = shift || 1;

    if ($level <= $self->{c_verbosity})
    {
	print $self->{c_label}, ": $msg\n";
	syslog("info", "spine: $msg")
            if ( not $self->{c_dryrun} or $log_to_syslog );
    }
}


sub print
{
    my $self = shift;
    my $lvl = shift || 0;

    if ($lvl <= $self->{c_verbosity})
    {
#	print $self->{c_label}, '[', join('::', caller()), ']: ', @_, "\n";
	print $self->{c_label}, ': ', @_, "\n";
    }
}


sub log
{
    my $self = shift;
    my $msg = shift;

    if (not $self->{c_dryrun}) {
        syslog('info', "spine: $msg");
    }
}


sub error
{
    my $self = shift;
    my ($msg, $level) = @_;
    return 0 unless ($level =~ m/
			       alert|crit|debug|emerg|err|error|
			       info|notice|panic|warning|warn
			       /xi );
    $msg =~ tr/\n/ -- /;

    unless ($self->{c_verbosity} == -1)
    {
	print STDERR $self->{c_label} . ": \[$level\] $msg\n";
    }

    syslog("$level", "spine: $msg")
        unless $self->{c_dryrun};
    push(@{$self->{c_errors}}, $msg);
}


sub get_release
{
    return (shift)->{c_release};
}


sub debug
{
    my $lvl = shift;

    if ($DEBUG >= $lvl) {
        print STDERR "DATA DEBUG($lvl): ", @_, "\n";
    }
}

#
# END plugins only
#

#
# FIXME  All of these need to be passed off to the new parser module
#
sub read_keyfile  { Spine::Parser::read_keyfile();  }
sub get_values    { Spine::Parser::get_values();    }
sub get_configdir { Spine::Parser::get_configdir(); }
sub get_config_group { Spine::Parser::get_config_group(); }


#
# Run time data access!
#

sub getval
{
    my $self = shift;
    my $key = shift;
    $self->cprint("getval -> $key", 4);
    return undef unless (exists $self->{$key});

    if ((ref $self->{$key}) eq "ARRAY")
    {
	return  $self->{$key}[0];
    }
    else
    {
	return $self->{$key};
    }
}


sub getval_last {
    my $self = shift;
    my $key = shift;
    $self->cprint("getval -> $key", 4);
    return undef unless (exists $self->{$key});

    if ((ref $self->{$key}) eq "ARRAY")
    {
	return  $self->{$key}[-1];
    }
    else
    {
	return $self->{$key};
    }
}


sub getvals
{
    my $self = shift;
    my $key = shift;
    $self->cprint("getvals -> $key", 4);
    return undef unless ($key && exists $self->{$key});

    if ((ref $self->{$key}) eq "ARRAY")
    {
	return $self->{$key};
    }
    else
    {
	return [$self->{$key}];
    }
}


sub getvals_as_hash
{
    my $self = shift;
    my $key = shift;

    $self->cprint("getval_as_hash -> $key", 4);

    return undef unless($key && exists($self->{key}));

    if (ref($self->{$key}) eq 'ARRAY')
    {
        # Make sure it's an array with an even number of elements(greater than
        # zero)
        my $oe = scalar(@{$self->{$key}});

        if ($oe and not ($oe % 2))
        {
            my %vals_as_hash = @{$self->{$key}};
            return \%vals_as_hash;
        }
    }
    elsif (ref($self->{$key}) eq 'HASH')
    {
        return $self->{$key};
    }

    return undef;
}


sub getvals_by_keyname
{
    my $self          = shift;
    my $key_re        = shift || undef;
    my @matching_vals = ();

    $self->cprint("getvals_by_keyname -> $key_re", 4);

    foreach my $key (keys(%{$self})) {
	if ($key =~ m/$key_re/o) {
	    push @matching_vals, $self->{key};
	}
    }

    # Sorted for minimal changes in diffs of templates
    @matching_vals = sort @matching_vals;
    return (scalar @matching_vals > 0) ? \@matching_vals : undef;
}


sub search
{
    my $self = shift;
    my $regex = shift;

    my @keys = grep(/$regex/, keys %{$self});
    return \@keys;
}


#
# This method checks its call stack to make sure that it isn't being called
# from anywhere inside Template::Toolkit and prevents any template from
# changing any "c_*" keys.
#
# FIXME  This should really happen for all the variables.  We should probably
#        have a Spine::Data::TemplateProxy class or similar that prevents a
#        template from modifying any data in it via TIE.  Shouldn't be too
#        difficult, come to think of it.
#
sub set
{
    my $self = shift;
    my $key = shift;
    my $in_template = 0;

    #
    # Check to see if the subroutine name for this frame begins with Template.
    # If it does, we disallow.
    #

    # We should never get a stack deeper than 30
    foreach my $i (1 .. 30) {
        my @frame = caller($i);

        if ($frame[3] =~ m/^Template/) {
            $in_template = 1;
            last;
        }
    }

    if ($in_template and $key =~ m/^c_/) {
        $self->error("We've got a template that's trying to call Spine::Data::set($key).  This is bad.");
        return 0;
    }

    if (exists($self->{$key})) {
        push @{ $self->{$key} }, @_;
    }
    #
    # If it's a reference of any kind, don't make it an array.  This permits
    # plugins to call $c->set('c_my_plugin', $my_plugin_obj).  ONLY do this if
    # there's only one argument passed in.  Otherwise, push them in as an array
    #
    # This bit me in the ass with the auth plugin's _grep_hash_element() method
    # while it spewed "Out of memory" to the console.
    #
    # rtilder    Tue Dec 19 15:52:52 PST 2006
    elsif (ref($_[0]) and scalar(@_) == 1) {
        $self->{$key} = $_[0];
    }
    else {
        $self->{$key} = [ @_ ];
    }

    return 1;
}


1;
