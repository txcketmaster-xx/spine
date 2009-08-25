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
#TODO implement a raw mode rather then just line by line
package Spine::Util::Exec;
use strict;
use IPC::Open3;
use Scalar::Util qw(blessed);
use IO::Select;
use IO::Handle;
use POSIX ":sys_wait_h";
use Spine::Constants qw(:basic);
use File::Spec::Functions;

use constant EXEC_KEY_EXTN => "_bin";
use constant COMPLEX_EXEC_KEY => "executable_paths";
use constant SPINE_PATH_KEY => "executable_search_paths";

# Create an object to manage execution of something
#    takes..
#        quiet        => <HIDE ERRORS>
#        exec         => <WHAT TO EXEC>
#        args         => <ARGS>
#        merge_error  => <JOIN STDERR to SEDOUT>
#        c            => <Spine::Data object>
#        inert        => <RUN WHEN IN DRYRUN>
sub new {
    my $class = shift;
    my %settings = @_;

    my $self = bless { ready  => 0,
                       dryrun => 0,
                       last_error => undef,
                     }, $class;
    
    # Check that we will be able to log errors
    unless ( exists  $settings{c} &&
             blessed($settings{c}) &&
             $settings{c}->isa("Spine::Data") ) {
        $self->{last_error} = "attempt to create a Spine::Util::Exec instance without".
                              " passing a Spine::Data object i.e. (data => \$c)";
        return $self;
    }
  
    $self->{c} = $settings{c};

    # check for executable        
    unless (exists $settings{exec} && defined $settings{exec}) {
        $self->_error("attempt to create a Spine::Util::Exec instance".
                      " without passing an executable name ".
                      "i.e (exec => \"something\")");
        return $self; 
    }
    
    # Used for logging         
    $self->{exec} = $settings{exec};
    
    # Are we suppressing errors
    $self->{quiet} = exists $settings{quiet} ? $settings{quiet} : 0;

    # can we run in dryrun
    $self->{inert} = exists $settings{inert} ? $settings{inert} : 0;
    
    # resolve the executable
    $self->{bin} = find_exec($self->{c}, $settings{exec});
 
    unless (defined $self->{bin}) {
        $self->_error("could not find executable");
        return $self;
    }

    if ( exists $settings{args} && defined
         $settings{args} ) {
        # Note that we split by space since many executables
        # will get upset if we pass everything as one arg
        $self->{args} = ref($settings{args}) eq "ARRAY" ?
                                $settings{args} :
                                [ split(' ', $settings{args}) ];
    } else {
        $self->{args} = [];
    }
    
             
    # set ready to yes so that we know we can run the command
    $self->{ready} = 1;
    
    # Create descripters for input and output
    my ($in, $out, $err) = (new IO::Handle, new IO::Handle);
    
    
    # create a new error descripter unless we
    # are merging out and error
    if ( !exists $settings{merge_error} &&
         $settings{merge_error} ) {
        $err = $out;
    }
    else {
        $err = new IO::Handle;
    }
    
    $self->{in} = $in;
    $self->{out} = $out;
    $self->{err} = $err;    

    # at this point 
    return $self;
}

# A very simple interface that can be used insted of new
sub simple {
    my $self = shift;
    
    # detect if we are being called after a call to new
    # if not we create ourselves.
    $self = new($self, @_) unless (blessed($self) &&
                                   $self->isa("Spine::Util::Exec"));
                                   
    my $c = $self->{c} if exists $self->{c};
    
    # FIXME:
    #   spine should deal with reporting this error, we can't
    #   since the error functions are within Spine::Data.
    #   perhaps error reporting should be a singlton?
    die "Spine::Data must be passed within exec\n"
        unless (blessed($c) && $c->isa('Spine::Data'));
    
 
    # Run command
    $self->start();
    
    # Get results (will hang untill EOF on STDOUT)
    my @result = $self->readlines();
    
    # Wait for it to exit, probably happend when
    # STDOUT closed but we need the exit code
    $self->isrunning() || $self->wait();
   
    # save the exit code where ther caller
    # expects it to be
    $? = $self->exitstatus();
    
    # Anything other then zero is probably bad
    unless ($self->exitstatus() == 0) {
        return wantarray ? () : SPINE_FAILURE;
    }
    
    return wantarray ? (@result) : SPINE_SUCCESS;
}

# Start the command, will just say ok if the command can't
# run due to dryrun
sub start {    
    my $self = shift;
    
    # the user could have tested if we are ready
    # after creating the object but we might as well
    # allow them just to check start.
    return SPINE_FAILURE unless $self->{ready};

    # can we run? if we are in dryrun and the command
    # has not been described as inert then we will skip
    # running.
    if ($self->{c}->getval('dryrun') &&
        (! exists $self->{inert} ||
         ! $self->{inert} )) {
        $self->{dryrun} = 1;
        $self->{exit_status} = 0;
        return SPINE_SUCCESS;
    }

    unless ($self->{quiet}) {
        $self->{c}->cprint("starting:". join(' ', $self->{bin},
                                            @{$self->{args}}), 3);
    }
    

    $self->{pid} = IPC::Open3::open3($self->{in},
                                     $self->{out},
                                     $self->{err},
                                     $self->{bin},
                                     @{$self->{args}});
        
    return SPINE_FAILURE unless $self->{pid};    
    return SPINE_SUCCESS;
}



# set last_error and print error unless in quiet
sub _error {
    my $self = shift;
    my $error = shift;
    
    $self->{last_error} = $error;
    if (exists $self->{exec} && defined $self->{exec}) {
        $self->{c}->error("exec of (".$self->{exec}."): ".$error,
                          "err") unless $self->{quiet};
    } else {
        $self->{c}->error("exec: ".$error,
                          "err") unless $self->{quiet};
    }
}

# Is it ready to run/running
sub ready {
    return $_[0]->{ready};
}

# return the last error or undef if there have been none
sub lasterror {
    my $self = shift;
    
    return exists $self->{last_error} ? $self->{last_error} : undef;
}

# If called then all the output will be returned
sub _readlines {
    my $self = shift;
    my $type = shift;
      
    return undef unless $self->{ready};
    
    my @output = $self->{$type}->getlines();
    if ($self->{$type}->error()) {
        $self->_error("some kind of read error happend, ".
                      "probably an invalid handle ($type)");
        $self->{$type}->clearerr();
    }
    
    return wantarray ? @output : join("", @output);
}

sub readlines {
    return shift->_readlines('out', @_);
}

sub readerrorlines {
    return shift->_readlines('err', @_);
}

# send some stuff to stdin
sub input {
    my $self = shift;
    
    return 0 unless $self->{ready};
    my $rc = $self->{in}->printflush(@_);
    if ($self->{in}->error()) {
        $self->_error("some kind of write error happend, ".
                      "probably an invalid/closed handle");
        $self->{in}->clearerr();
    }
    return $rc;
}

# close stdin
sub closeinput {
    my $self = shift;
    return 0 unless $self->{ready};
    return $self->{in}->close();
}

# Read a line of input (with a timeout)
# default timeout is never.
# first arg is  (err or out)
sub _readline {
    my $self = shift;
    my $type = shift;
    my $timeout = shift;
    
    return undef unless $self->{ready};
    
    my $sel = $self->_get_select();
    
    $sel->add($self->{$type});
    my @ready = $sel->can_read($timeout);
    $sel->remove($self->{$type});
    
    # Check if any were returned, if none then a timeout happend
    unless (@ready && length(@ready)) {
        $self->_error("no data avaliable within timeout");
        return undef;
    }
    
    # attemt to catch that there was an error before calling
    # getline, this is because select can return a fd when in error
    if ($self->{$type}->error()) {
        $self->_error("some kind of read error happend, ".
                      "probably an invalid/closed handle");
        $self->{$type}->clearerr();
        return undef;
    }
    my $line = undef;
    eval {
        $SIG{ALRM} = sub { die "timeout" };
        alarm($timeout || 0);   
        $line =  $self->{$type}->getline();
        alarm(0);
    };
    if ($@) {
        $self->{last_error} = "$@";
        return undef;
    }
    return $line;
}

# read a line for stdout
sub readline {
    my $self = shift;
    return $self->_readline("out", @_);
}

# read a line from stderr
sub readerrorline {
    my $self = shift;
    return $self->_readline("err", @_);
}

# create a new IO::Select object as needed
sub _get_select {
    my $self = shift;
    
    unless (exists $self->{select}) {
        $self->{select} = new IO::Select;
    }
    
    return $self->{select};
}

# Wait for the process to finish
sub wait {
    my $self = shift;
    
    return $self->{exit_code} if exists $self->{exit_code};
    
    return 1 unless exists($self->{pid});
    
    waitpid($self->{pid}, 0);
    $self->{exit_code} = $?;
    return $self->{exit_code};
}

# Will return true if the process is still runnign
sub isrunning {
    my $self = shift;
    my $pid;

    return 0 if (exists $self->{exit_code} ||
                 ! $self->{ready} ||
                 ! exists $self->{pid});
    
    # Will return the pid if it's finished 0 if not
    # and -1 if it never started
    unless ($pid = waitpid($self->{pid}, WNOHANG)) {
        return 1;
    }
    
    # Store the exit code
    if ($pid > 0) {
        $self->{exit_code} = $?;
    } else {
        $self->_error("seems the process never started");
    }
    
    return 0;
}

# Return the return code fo the command, if waitpid
# has not been called then we also wait first.
sub exitstatus {
    my $self = shift;
    unless (exists $self->{exit_code}) {
        $self->wait();
    }
    
    return $self->{exit_code};    
}

# Try to find a executable
sub find_exec {
    my $self = shift if ($_[0]->isa("Spine::Util::Exec"));
    my ($c, $bin_name, @arg_paths) = @_;

    return undef unless (defined $c && defined $bin_name);

    # If bin_name is absolute then check if it exists
    if (File::Spec->file_name_is_absolute($bin_name)) {
        if ( -x $bin_name ) {
            return $bin_name;
        }
        # Since it's a absolute path but there was no binary found
        # we return undef.
        return undef;
    }

    # Does a path exists within the executable_paths key
    my $bin_paths = $c->getval(COMPLEX_EXEC_KEY);
    if (ref($bin_paths) eq "HASH" && exists $bin_paths->{$bin_name}) {
        return $bin_paths->{$bin_name} if ( -x $bin_paths->{$bin_name});
        # We genarate a warning as the user may have intended this to work
        # and may be confused if it runs a different copy of the executable
        $c->error("A path for $bin_name was defined within ".COMPLEX_EXEC_KEY.
                  " but the path was not valid", 'warning');
    }

    # Is there a separate key to represent the path?
    my $bin_path = $c->getval($bin_name . EXEC_KEY_EXTN);
    if (defined $bin_path) {
        return $bin_path if ( -x $bin_path );
        # Again, let the user know that what they defined is wrong/missing
        $c->error("A path for $bin_name was defined within '$bin_name" .
                  EXEC_KEY_EXTN . "' but the path was not valid", 'warning');
    }

    # check through spine_paths, arg_paths and then env_paths trying to find it
    my $search_path = $c->getvals(SPINE_PATH_KEY);
    $search_path = [] unless defined $search_path;
    foreach my $path (@{$search_path},
                      @arg_paths,
                      File::Spec->path()) {
        next unless defined $path;
        $bin_path = catfile($path, $bin_name);
        return $bin_path if ( -x $bin_path );
    }

    # Nothing worked so give up...
    return undef;
}

1;
