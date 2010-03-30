
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

use strict;

package Spine::Registry;
use base qw(Spine::Singleton Exporter);
use Carp qw(cluck);
use Spine::Constants qw(:basic :plugin);
use Spine::Chain;

our ($VERSION, $DEBUG, @EXPORT, @EXPORT_OK);

$DEBUG = $ENV{SPINE_REGISTRY_DEBUG} || 0;
$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);

@EXPORT_OK = qw(register_plugin create_hook_point add_option get_options
                add_hook get_hook_point install_method get_plugin_version);

sub _new_instance
{
    my $klass = shift;

    return bless { CONFIG       => shift,
                   PLUGINS      => {},
                   POINTS       => {},
                   OPTIONS      => {}
                 }, $klass;
}

#
# Method to retrieve a given plugin's version
#
sub get_plugin_version
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    my $plugin_name = shift;
    $plugin_name = 'Spine::Plugin::' . $plugin_name;

    if (exists($registry->{PLUGINS}->{$plugin_name}->{version})) {
        return $registry->{PLUGINS}->{$plugin_name}->{version};
    }
    else {
        return undef;
    }
}

#
# Adds a new entry in our "points" location that a plugin can hook at.
#
sub create_hook_point
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    my $CONFIG = $registry->{CONFIG};

    foreach my $new_point (@_) {
        debug(5, "\tCreating hook point \"$new_point\"");

        if (exists($registry->{POINTS}->{$new_point})) {
            next;
        }

        my @caller = caller();

        my $point = new Spine::Registry::HookPoint(name => $new_point,
                                                   'caller' => \@caller);
        
        # Add some standard rules (used for START MIDDLE and END)
        $point->add_rule(provide  => HOOK_MIDDLE,
                         succedes => [ HOOK_START ]);
        $point->add_rule(provide  => HOOK_END,
                         succedes => [ HOOK_START, HOOK_MIDDLE ]);



        $registry->{POINTS}->{$new_point} = $point;
    }

    return SPINE_SUCCESS;
}


#
# Try to load the full plugin name as is first but fallback to something in the
# Spine::Plugin namespace, plugin must not be a full path to a file.
#
# There's no problem problem with plugins being loaded repeatedly, since they
# should all be singletons.
#
sub load_plugin
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    my $rc = SPINE_SUCCESS;
    my $module;

    my $plugin;
    foreach (@_) {
        # XXX: must assign to ensure it's rw
        $plugin = $_;

        eval "require $plugin";

        if ($@) {
            if ($plugin =~ m/^Spine::Plugin::/) {
                error("Failed to find or load $plugin: $@");
                $rc = SPINE_FAILURE;
                next;
            }

            # And our fallback
            eval "require Spine::Plugin::$plugin";

            if ($@) {
                error("Failed to find or load $plugin fallback as ",
                      "\"Spine::Plugin::$plugin\": $@");
                $rc = SPINE_FAILURE;
                next;
            }
        }

        $plugin = 'Spine::Plugin::' . $plugin;

        eval {
            $module = $plugin->new();
        };

        if ($@ or not defined($module)) {
            error("Failed to instantiate plugin \"$plugin\": $@");
            $rc = SPINE_FAILURE;
        }
    }

    return $rc;
}


#
# Registers a plugin with the registry without actually doing much useful work.
# Currently only populates our command line options.
#
sub register_plugin
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    my $plugin = shift;

    unless (UNIVERSAL::isa($plugin, 'Spine::Plugin')) {
        error('Invalid object given as first parameter to register_plugin: ',
              ref($plugin));
        return SPINE_FAILURE;
    }

    my $module = shift;
    my $module_name = ref($plugin);

    debug(2, "\tRegistering plugin \"$module_name\"");

    # If this plugin has already been registered, notify but continue on
    if (exists($registry->{PLUGINS}->{ref($plugin)})) {
        debug(2, "Duplicate registration of plugin: \"$module_name\"");
        return SPINE_SUCCESS;
    }

    $registry->{PLUGINS}->{$module_name} = $module;

    # We register command line stuff first because it's possible that the
    # hook points supported by this particular plugin don't exist.

    # Register this plugins command line options
    if (exists($module->{cmdline})) {
        unless ($registry->add_option($module_name, $module->{cmdline})) {
            error("Failed to register command line for \"$module_name\""),
            return SPINE_FAILURE;
        }
    }

    return SPINE_SUCCESS;
}


sub find_plugin
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    my @plugins;
    my $PLUGINS = $registry->{PLUGINS};

    #
    # Looks for the plugin name in the Spine::Plugin::* namespace first and
    # if it fails to find it, attempts to find the plugin by itself.
    #
    foreach my $candidate (@_) {
        foreach my $module ( ("Spine::Plugin::$candidate", $candidate) ) {
            if (exists($PLUGINS->{$module})) {
                push @plugins, $module;
                last;
            }
        }
    }

    if (wantarray) {
        return @plugins;
        
    }

    return length(@plugins) ? shift @plugins : undef;
    
}


sub add_option
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    my (%cmdline, $prefix);
    my $plugin = shift;

    # If we were passed a hashref then try to be smart.
    if (ref($_[0]) eq 'HASH') {
        %cmdline = %{ shift() };
    }
    else {
        %cmdline = @_;
    }

    # Populate our prefix if it exists
    if (defined($cmdline{'_prefix'})) {
        $prefix = delete $cmdline{'_prefix'};
    }

    if (exists($registry->{OPTIONS}->{$plugin})) {
        error("Duplicate command line options entry for \"$plugin\"");
        return SPINE_FAILURE;
    }

    my $final = {};

    while (my ($opt, $target) = each(%{$cmdline{options}})) {
        $opt = defined($prefix) ? $prefix . '-' . $opt : $opt;

        if (exists($registry->{OPTIONS}->{$opt})) {
            error("Duplicate command option specific by $plugin: \"$opt\"");
            return SPINE_FAILURE;
        }

        $registry->{OPTIONS}->{$opt} = $target;
    }

    return SPINE_SUCCESS;
}


sub get_options
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    return $registry->{OPTIONS};
}


sub get_hook_point
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    my @points;

    foreach my $hook_point (@_) {
        unless (exists($registry->{POINTS}->{$hook_point})) {
            $registry->create_hook_point($hook_point);
        }

        push @points, $registry->{POINTS}->{$hook_point};
    }

    if (scalar(@_) == 1 and scalar(@points) == 1) {
        return shift @points;
    }

    return wantarray ? @points : \@points;
}



sub install_method
{
    my $registry = Spine::Registry->instance();

    if (UNIVERSAL::isa($_[0], 'Spine::Registry')) {
        shift;
    }

    my ($method_name, $coderef) = @_;

    my $dest = 'Spine::Data::' . $method_name;

    no strict 'refs';
    if (defined(*{$dest})) {
        error("Duplcate method in Spine::Data: \"$method_name\"");
        return SPINE_FAILURE;
    }

    *{$dest} = $coderef;
    use strict 'refs';

    return SPINE_SUCCESS;
}


sub error
{
    print STDERR 'REGISTRY ERROR: ', @_, "\n";
}


sub debug
{
    my $lvl = shift;

    if ($DEBUG >= $lvl) {
        print STDERR "REGISTRY DEBUG($lvl): ", @_, "\n";
    }
}


##############################################################################
#
# Finally needed to create a Spine::Registry::HookPoint class
#
##############################################################################

package Spine::Registry::HookPoint;
use Spine::Constants qw(:plugin :basic);

our $DEBUG = $ENV{SPINE_REGISTRY_DEBUG} || 0;

sub new
{
    my $klass = shift;
    my %args = @_;

    my $self = bless { name => $args{name},
                       owner => $args{'caller'} ? $args{'caller'} : undef,
                       parameters => $args{parameters} ? $args{parameters} : [],
                       states => {},
                       hooks => new Spine::Chain,
                       status => SPINE_NOTRUN,
                       registered => SPINE_NOTRUN }, $klass;

    return $self;
}


sub add_parameter
{
    my $self = shift;

    return push @{ $self->{parameters} }, @_;
}


# Wil normally register all plugins hooks based on profile.
# if a plugin name is passed then it will register it's hooks
sub register_hooks
{
    my $self = shift;
    # optinal
    my $plugin = shift;
    my $registry = Spine::Registry->instance();

    unless ($self->{registered} == SPINE_NOTRUN || defined $plugin) {
        return $self->{registered};
    }

    $self->debug(4, "\tRegistering hooks for hook point \"$self->{name}\"");

    # If we've already loaded our plugin lists, make sure we add populate
    # this hook point's children
    my $c = $registry->{CONFIG};
    my @modules;
    if (defined $plugin) {
        @modules = ($registry->find_plugin($plugin));
    } else {
        # make sure there is something defined in the config, if not it's
        # not really an error just means ther user doesn't want anythign run
        unless (exists $c->{$c->{spine}->{Profile}}->{$self->{name}}) {
        	return SPINE_SUCCESS;
        }
        @modules = $registry->find_plugin(split(/(?:\s*,?\s+)/,
                                                $c->{$c->{spine}->{Profile}}->{$self->{name}}));
    }

    foreach my $module (@modules) {
        unless ($self->install_hook($module, $registry->{PLUGINS}->{$module})) {
            $self->{registered} = SPINE_FAILURE;
            goto register_hooks_out;
        }
    }

    $self->{registered} = SPINE_SUCCESS;

  register_hooks_out:
    return $self->{registered};
}


sub install_hook
{
    my $self = shift;
    my $module_name = shift;
    my $module = shift;

    foreach my $hook (@{$module->{hooks}->{$self->{name}}}) {
        $self->debug(5, "\t\tRegistering hook at \"$self->{name}\": ",
                     $hook->{name});

        unless ($self->add_hook($module_name, $hook)) {
            $self->error("Failed to add hook \"${module}::$hook->{name}\" ",
                         "to \"$self->{name}\"");
            return PLUGIN_ERROR;
        }
    }

    return SPINE_SUCCESS;
}

sub head
{
    return $_[0]->{hooks}->head;
}

sub count
{
    return $_[0]->{hooks}->count();
}
 
sub next
{
    if (UNIVERSAL::isa($_[0], 'Spine::Registry::HookPoint')) {
        shift;
    }
    return wantarray ? ($_[0]->{next}, $_[0]->{data}) : $_[0]->{next};
}



sub add_hook
{
    my $self = shift;

    my ($module, $h) = @_;

    # If $module is a reference to a Spine::Plugin object, convert it to a
    # string we can use for better error reporting.
    unless (ref($module) eq '') {
        $module = ref($module);
    }

    my $hook = { module => $module,
                 name => $h->{name},
                 code => $h->{code},
                 rc => PLUGIN_ERROR,
                 msg => undef };
 
    unless (exists $h->{position}) {
        $h->{position} = HOOK_MIDDLE;
    }
    
    # position is actually just a provides wiht some rules defined
    # when this hook point was created.
    $h->{provides} = [] unless exists $h->{provides};
    push @{$h->{provides}}, $h->{position};

    $self->{hooks}->add(
        name => $h->{name},
        data => $hook,
        provides => $h->{provides},
        requires => exists $h->{requires} ? $h->{requires} : undef,
        succedes => exists $h->{succedes} ? $h->{succedes} : undef,
        precedes => exists $h->{precedes} ? $h->{precedes} : undef
    );

    return SPINE_SUCCESS;
}

# TODO document what this does
sub add_rule {
    my $self = shift;
    
    return $self->{hooks}->add_provide_rule(@_);
}

# simple wrapper for run_hooks_until, it will run until
# EXIT, FINAL or FATAL. FATAL is EXIT + ERROR but we check
# for both in case this changes in future.
sub run_hooks {
    my $self = shift;

    return $self->run_hooks_until(PLUGIN_STOP, @_);
}

# run hooks until a condition is met or we have
# run all the hooks
sub run_hooks_until {
    my $self = shift;
    my $until = shift;

    # It is now set in stone that Spine::Data must be the
    # first argument passed to hooks
    my $c = $_[0];
    unless ($c->isa('Spine::Data')) {
        $self->error("Spine::Data must be passed when running hooks");
        # attempt to make sure that the caller will bail out if this happens
        return ([ "CORE", PLUGIN_FATAL, undef ], PLUGIN_FATAL, 1);
    }

    my $errors = 0;
    my $fatal = 0;

    $self->debug(2, "Running hooks for \"$self->{name}\"");

    unless ($self->register_hooks() == SPINE_SUCCESS) {
        return PLUGIN_FATAL;
    }

    # catch no hooks and return NOHOOKS
    return ([], PLUGIN_NOHOOKS, 0) unless $self->count();

    my (@results, $rc);
    
    foreach my $hook ($self->head()) {
        $rc = $self->run_hook($hook, @_);

        # Allow the caller to see what happend to every hook
        push @results, [ $hook->{name}, $rc , $hook];

        if (($rc & PLUGIN_FATAL) == PLUGIN_FATAL) {
            $c->error("FATAL error while running hook ".
                      "\"$hook->{module}::$hook->{name}\" ".
		      "for \"$self->{name}\"", "crit");
            $fatal++;
        }
        elsif ($rc & PLUGIN_ERROR) {
            $c->error("ERROR while running hook ".
                      "\"$hook->{module}::$hook->{name}\" for ".
		      "\"$self->{name}\"", "warn");
            $errors++;
        }

        if ($until & $rc) {
            $self->debug(3, "UNTIL condition met while ".
                            "running hook for \"$self->{name}\"");
            last;
        }
    }
    
    # If this is defined then it will either be a missing requirement
    # or a loop within the dependancies. Hopefuly this will only be hit
    # by developers.
    my $last_err = $self->last_head_error();
    if (defined $last_err) {
        $c->error("Issue with hook ordering/requirements, $last_err",
                  'err');
        return SPINE_FAILURE;
    }
                 

    # FIXME: not sure this makes much sense, all this will do is
    #        force register_hooks to run again if there were any errors...
    if ($errors + $fatal) {
        $self->{status} = SPINE_FAILURE;
    }

    # We always return an array, if the caller doesn't take all
    # the arguments then they will get errors+fatal by it's self
    return (\@results, $rc, ($errors + $fatal));
}

sub last_head_error {
    my $self = shift;
    return $self->{hooks}->last_error();
}

sub run_hook
{
    my $self = shift;
    my $hook = shift;
    my @parameters = @_;
    my $c = $parameters[0];

    unless ($self->register_hooks() == SPINE_SUCCESS) {
        return PLUGIN_FATAL;
    }

    $self->debug(3, "Running hook: $hook->{name}");
    $self->debug(6, 'Parameters: ', @parameters);

    unless (ref($hook) eq 'HASH'
            and ref($hook->{code}) eq 'CODE') {
        $self->error('Invalid hook passed to run_hook! ');
        $hook->{rc} = PLUGIN_FATAL;
        goto hook_error;
    }

    unless ($c->isa('Spine::Data')) {
        $hook->{rc} = PLUGIN_FATAL;
        $self->error('First parameter passed to run_hook is not a '.
	             'Spine::Data object: "' . ref($_[0]).'"');
        goto hook_error;
    }

    my $old_label = $c->{c_label};
    $c->set_label($hook->{name});

    eval {
        # FIXME  This is going to be fugly to implement.
        #local $SIG{__DIE__} = \&_plugin_die;

        $hook->{rc} = &{$hook->{code}}(@parameters);
    };

    $c->set_label($old_label);

    # FIXME  Proper exception handling.
    if ($@) {
        $hook->{rc} = PLUGIN_FATAL;
        $c->error("Hook \"$hook->{module}::$hook->{name}\" failed: " . $@, "crit");
        goto hook_error;
    }

    unless (exists($self->{states}->{$hook->{rc}})) {
        $self->{states}->{$hook->{rc}} = [];
    }

    push @{$self->{states}->{$hook->{rc}}}, $hook;

    if ($hook->{rc} == PLUGIN_EXIT) {
        $self->debug(3, 'Hook "', $hook->{module}, '::', $hook->{name},
                     '" completed successfully but returned PLUGIN_EXIT');
    }

  hook_error:
    return $hook->{rc};
}


sub get_state
{
    my $self = shift;
    my $wanted = shift;

    my $states = $self->{states}->{$wanted};

    unless (defined($states)) {
        return wantarray ? () : [];
    }

    return wantarray ? @{$states} : $states;
}


sub error
{
    my $self = shift;

    print STDERR "REGISTRY ERROR($self->{name}): ", @_, "\n";
}


sub debug
{
    my $self = shift;
    my $lvl = shift;

    if ($DEBUG >= $lvl) {
        print STDERR "REGISTRY DEBUG($self->{name}:$lvl): ", @_, "\n";
    }
}


1;
