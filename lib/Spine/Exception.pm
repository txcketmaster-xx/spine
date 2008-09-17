# -*- mode: cperl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Exception.pm,v 1.1.2.2 2007/09/11 21:27:58 rtilder Exp $

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
# Almost all of this is stolen blatanly from TMCS::Exception.  Sadly, I can't
# include that verbatim here.
#

package Spine::Exception;

use strict;
use Carp;

use base qw(Exporter);
#require Exporter;

use overload (
    '""'        => 'stringify',
    'fallback'  => 1,
);

our ($AUTOLOAD, $STACK_TRACE);
$STACK_TRACE = 0;

BEGIN {
    $SIG{__DIE__} = \&_my_die;
}


# Outright thievery!
#
# This permits the following kind of usage:
#
# use Spine::Exception qw(Spine::Exception::Fatal Spine::Plugin::SmellsBad);
#
# Spine::Exception::Fatal and Spine::Plugin::SmellsBad automatically get
# created as catchable exception classes.
#
# This import creates the convenience subclasses
sub import {
    my $pkg = shift;

    $pkg->export_to_level(1, qw(throw));

    foreach my $class (@_) {
        no strict 'refs';

        next unless $class =~ /((\w+)(::)?)+/o;
        my $isa_name = join('', $class, '::ISA');
        next if defined @{$isa_name};

        @{$isa_name} = (__PACKAGE__);
    }
}


####################################################################
#
# Overload Die. Text only arguments to die are converted
# to Spine::Exception objects and rethrown.
#
# This does not conform to the 'best practice' way of overriding
# CORE::GLOBAL::die that can be found in the mod_perl guide.
# The reason for this is that the methodology given there
# (export a local die with (@) prototype to CORE::GLOBAL::die)
# does not play nice with object methods.  That is to say that
# code which looks like this fails:
#
#   die Some::Object->new(some => args);
#
# Due to some incomprehensible prototyping issues, what the custom
# die function gets as an argument is the string 'Some::Object'
# instead of the object itself.  Adding parentheses does work:
#
#   die(Some::Object->new(some => args);
#
# Because we don't want to go changing all our CPAN libraries'
# usage of die, the CORE::GLOBAL::die methodology was abandoned.
#
# Setting $SIG{__DIE__} gives us better behaviour in this regard.
# Using SIG{__DIE__} is not recommended and is supposed to be
# deprecated.  It also has some quirks of its own (see comments
# in the constructor).  However, it seems to be the only way to
# go.
#
# If someone figures out how to fix the CORE::GLOBAL::die issue,
# please let us know!!
#
# See http://perl.apache.org/guide/perl.html#Exception_Handling_for_mod_perl
# for Stas' implementation of the CORE::GLOBAL::die override.
#

sub _my_die {
    if (!ref($_[0])) {
        my $text = join('', @_);
        CORE::die Spine::Exception->new(text => $text, modify_depth => 1);
    }
    CORE::die $_[0]; # only use first element because its an object
}

#############################################################
#
# Core Routines
#

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;

    # If we have only one argument and it's a simple string, make that the text
    # data member
    if (scalar(@_) == 1 and not ref($_[0])) {
        unshift @_, 'text';
    }

    my %args = @_;
    my $modify = $args{modify_depth} || 0;
    my($pkg, $file, $line) = caller($modify);

    my $err = bless {
        'package'   => $pkg,
        'file'      => $file,
        'line'      => $line,
        @_
    }, $class;

    # Explaining why this is here would be a long tale indeed.
    # Suffice it to say the the technique of setting SIG{__DIE__}
    # causes context sensitive behaviour.  The thrown error is
    # formatted differently for a die "text" then for a runtime error.
    # The main point here is to normalize the text attribute so that
    # it never contains the filename or line number.
    if (defined($err->{text}) &&
        $err->{text} =~ m/^(.*) at (.*) line (.*)\.$/o) {
        $err->{text} = $1 if ($file eq $2) && ($line eq $3);
    }

    # To always create a stacktrace would be very inefficient, so
    # we only do it if $Spine::Exception::STACK_TRACE is set

    if ($Spine::Exception::STACK_TRACE) {
        local $Carp::CarpLevel = $modify;
        my $text = defined($err->{'text'}) ? $err->{'text'} : "Error";
        my $trace = Carp::longmess($text);

        # Carp::Heavy::longmess seems to mis-interpret eval BLOCK as a require.
        # Rewrite it to make a little more sense
        $trace =~ s/require 0/eval BLOCK/go;

        $err->{'stacktrace'} = $trace
    }

    $@ = $err;
}

sub throw {
    my $self = shift;
    my %args = @_;
    $args{modify_depth}++;

    # only create a new error object if one does not already exist
    $self = $self->new(%args) unless ref($self);

    CORE::die($self);
}

*raise = *throw;

#############################################################
#
# Accessors
#
sub stringify {
    my $self = shift;
    my $string = defined $self->{'text'} ? $self->{'text'} : "Died";
    return join('', $string, ' at ', $self->file, ' line ', $self->line)
        if $self->file && $self->line;
    return $string;
}

sub file {
    my $self = shift;
    exists $self->{'file'} ? $self->{'file'} : undef;
}

sub add_error {
    my $self = shift;
    if (defined($self->{errors}) and ref($self->{errors}) eq 'ARRAY') {
        push @{$self->{errors}}, @_;
    }
}

sub errors {
    my $self = shift;
    exists $self->{'errors'} ? $self->{'errors'} : undef;
}


sub line {
    my $self = shift;
    exists $self->{'line'} ? $self->{'line'} : undef;
}

sub text {
    my $self = shift;
    if (@_) {
        $self->{'text'} = shift;
    }
    exists $self->{'text'} ? $self->{'text'} : undef;
}

sub stacktrace {
    my $self = shift;

    return $self->{'stacktrace'}
        if exists $self->{'stacktrace'};

    my $text = exists $self->{'text'} ? $self->{'text'} : "Died";

    $text .= sprintf(" at %s line %d.\n", $self->file, $self->line)
        unless($text =~ /\n$/s);

    $text;
}

# catch anything else
sub AUTOLOAD {
    my $self = shift;

    my $name = $AUTOLOAD;
    $name =~ s/.*://o;   # strip fully-qualified portion

    return $self->{$name};
}

# Override isa to avoid long crawls up the name space
sub isa {
    UNIVERSAL::isa(@_);
}


=pod

=head1 NAME

Spine::Exception - Exception handling methods and superclass

=head1 SYNOPSIS

  use Spine::Exception qw (My::Exception::Class1
                           My::Exception::Class2
                           My::Exception::Class3);

  use Spine::Exception;

  # Programming with exceptions
  eval {
      # some code
      die "some kind of error"
          if (something);

      throw My::Exception::Class1(text => "some kind of error")
          if (something_else);

      throw My::Exception::Class1(text => "some kind of error")
          if (something_different);
  };
  if ($@) {
      my $err = $@;
      if    ($err->isa('My::Exception::Class1')) {
            # do something
      }
      elsif ($err->isa('My::Exception::Class2')) {
            # do something else
      }
      else {
            # Unhandled, throw it up and hope something up the stack
            # can deal with it
            throw $err;
      }
  }

  # Informational methods on exception objects
  $str = $exception->text;
  "$exception"
  $str = $exception->file;
  $num = $exception->line;
  $list = $exception->errors;

  # Stacktracing
  $Spine::Exception::STACK_TRACE = 1;
  $text = $exception->stacktrace;

=head1 DESCRIPTION

Spine::Exception provides a mechanism for exception handling in perl.  It
encapsulates an error as an object and provides an interface for throwing and
catching that error.  It also overrides the global B<die> function to
guarantee that caught errors will always be an object, no matter where the
error originated.

=head1 THROWING EXCEPTIONS

Exceptions can be thrown with a B<die> or a B<throw> command.  B<Dies> can
take a text argument which will be auto-magically converted into a
Spine::Exception object.  You can throw Spine::Exception objects or subclasses
of that object.  The B<throw> method is a constructor so you can throw and
create your exception object with one line of code:

  throw Spine::Exception(text => "I have a problem!");

=head1 CATCHING EXCEPTIONS

Blocks of code that are expected to throw up exceptions should be run inside
of an eval.  After the eval block has run, the $@ perl variable will contain
the exception object if one was thrown.  When using Spine::Exception, $@ is
always guaranteed to be an object of type Spine::Exception or one of its
subclasses.

If $@ is a subclass, you can use the B<isa> method to identify it.

If the exception is not of a type that will be handled locally, it should be
rethrown so that something higher up the call stack has an opportunity to deal
with it.

  eval { ... };
  if ($@) {
      my $err = $@;
      if ($err->isa('Exception::Class1') {
          ...
      }
      elsif ($err->isa('Exception::Class2') {
          ...
      }
      else {
          # Don't forget to rethrow!!
          throw $err;
      }
  }

B<NOTE:> Calling methods on $@ seems to cause strange errors in certain
scenarios.
It is always better to assign $@ to some other variable and call methods on it
instead.

=head1 EVIL VOODOO: EVALS AND DESTROYS

Be very carefull with DESTROY blocks.  An eval that fails and will be expected
to throw an exception will still call the DESTORY blocks on objects that go
out of scope with the eval.  If any code within those DESTROY blocks use evals,
you can lose the value of $@.

To avoid this, you should always localize $@ at the beginning of any DESTROY
block.

  package SomeObject;

  sub DESTROY {
    my $self = shift;
    local $@;

    ....
  }

=head1 CREATING EXCEPTION SUBCLASSES

You can create subclasses of Spine::Exception as a convenience for determining
the type of exception (see examples above).  Because most of these classes are
created for the sole purpose of distinguishing themselves from other classes,
creating the package files for them becomes tedious and wasteful since these
files usually contain nothing more than an ISA declaration.

As a convenience, Spine::Exception provides a simple mechanism by which you can
create a whole set of exception subclasses all at once and without having to
create the package files.  The LIST arguments to the B<use> will be taken and
converted directly into subclasses:

  use Spine::Exception qw (  Spine::Exception::SubClass1
                            Spine::Exception::SubClass2::SubSubClassA
                            Spine::Plugin::Overlay::Exception::TypeA
                         );

This will create the name spaces and necessary ISA declarations for all of the
listed classes on compilation.

Note that if you want to create exception classes that override methods or add
new methods, you will have to create the class files the old fashioned way.

B<WARNING:> Never do a B<use Spine::Exception ();>!  This will cause the import
function to not be called and will break the global override of the B<die>
function.

=head1 CONSTRUCTORS

Both B<new> and B<throw> can be used to construct an exception object.  The
only difference between them is that B<new> simply returns the object.  It
does not throw it.

=over 4

=item new constructor

  $ref = new Spine::Exception(   text         => "oh my god! I'm broken!",
                                line         => 12,
                                file         => "SomeModule.pm",
                                modify_depth => 1,
                                other        => 'user'
                                defined      => 'attributes',
                                ...
                            );
  throw Spine::Exception(text    => "ARGH!!");

All arguments to the constructors are optional, however the B<text> argument is
highly recommended if you expect to print out or log the error.  The B<line>
and B<file> arguments are intended to indicate where the error occurred.  They
will be automatically filled in with the appropriate data if they are not
supplied.

The B<modify_depth> argument allows you to control how far up the call stack
'line' and 'file' are generated from.  This argument is optional and defaults
to zero.

Any other arguments given will be available as autoloaded accessor methods.

=back

=head1 METHODS

=over 4

=item throw

  throw Spine::Exception(
                text         => "some text",
                line         => 12,
                file         => "SomeModule.pm",
                modify_depth => 1,);

Invokes the B<new> method to create an exception object and throws it
up the call stack.

=item text

  $string = $exception->text();

Returns the text of the error message that was set during construction.

=item file

  $string = $exception->file();

Returns the filename in which the error occurred.

=item line

  $num = $exception->line();

Returns the line number on which the error occurred.

=item errors

  $num = $exception->errors();

Returns array array of error messages included in this excetpion.

=item isa

  if ($exception->isa('Some::Class')) { ... }

Returns a true or false indication of whether the exception object matches the
supplied class name or hierarchy.  This operates exactly like UNIVERSAL::isa.

=item stacktrace

  $Spine::Exception::STACK_TRACE = 1;
  print $exception->stacktrace();

This method returns a stack trace of the error.  Since stacktraces are
generally expensive, Spine::Exception will only generate them when its package
global B<$Spine::Exception::STACK_TRACE> is set.

=item stringify

  $str = "$exception";

Exception objects know how to stringify themselves when embedded in strings or
otherwise interpolated in a scalar context.  Stringified exceptions will take
the form of:

  <text> at <file> line <line>.

=back

=cut



package Spine::Exception::Exit;
use Spine::Exception;
our (@ISA);
@Spine::Exception::Exit::ISA = qw(Spine::Exception);

1;
