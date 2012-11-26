## $Id$
#####################################################################
package POEx::Inotify;

use 5.008008;
use strict;
use warnings;

our $VERSION = '0.0101';
$VERSION = eval $VERSION;  # see L<perlmodstyle>

use POE;
use POE::Session::PlainCall;
use Storable qw( dclone );

use Linux::Inotify2;

sub DEBUG () { 0 }

#############################################
sub spawn
{
    my( $package, %init ) = @_;

    my $options = delete $init{options};
    $options ||= {};

    POE::Session::PlainCall->create(
                    package   => $package,
                    ctor_args => [ \%init ],
                    options   => $options,
                    states    => [ qw( _start _stop shutdown
                                       poll inotify
                                       monitor unmonitor
                                 ) ]
                );
}


#############################################
sub new
{
    my( $package, $args ) = @_;

    my $self = bless {
                       path=>{}         # path => $notifies
                     }, $package;
    $self->{alias} = $args->{alias} || 'inotify';
    $self->build_inotify;
    return $self;
}

#############################################
sub _start
{
    my( $self ) = @_;
    DEBUG and warn "$self->{alias}: _start";
    poe->kernel->alias_set( $self->{alias} );
    poe->kernel->sig( shutdown => 'shutdown' );
    $self->setup_inotify;
}

#############################################
sub _stop
{
    my( $self ) = @_;
    DEBUG and warn "$self->{alias}: _stop";
}

#############################################
sub shutdown
{
    my( $self ) = @_;
    DEBUG and warn "$self->{alias}: shutdown";
    $self->{shutdown} = 1;
    foreach my $path ( keys %{ $self->{path} } ) {
        local $self->{force} = 1;
        $self->unmonitor( { path=>$path } );
    }
    poe->kernel->select_read( $self->{fh} ) if $self->{fh};
    poe->kernel->alias_remove( $self->{alias} );
    delete $self->{fh};
}

#############################################
sub build_inotify
{
    my( $self ) = @_;
    $self->{inotify} = Linux::Inotify2->new;
}

#############################################
sub setup_inotify
{
    my( $self ) = @_;
    $self->{inotify}->blocking( 0 );
    $self->{fh} = IO::Handle->new_from_fd( $self->{inotify}->fileno, "r" );
    poe->kernel->select_read( $self->{fh}, 'poll' );
}

sub add_inotify
{
    my( $self, $path, $mask ) = @_;
    DEBUG and warn sprintf "$self->{alias}: mask=%08x path=$path", $mask;
    return $self->{inotify}->watch( $path, $mask, 
                                    poe->session->callback( inotify=>$path ) );
}

#############################################
# Poll the Inotify object
sub poll
{
    my( $self ) = @_;
    return if $self->{shutdown};
    DEBUG and warn "$self->{alias}: poll";
    $self->{inotify}->poll
}

#############################################
# Callback from Inotify object
sub inotify
{
    my( $self, $N, $E ) = @_;
    my $notify = $self->_find_path( $N->[0] );
    next unless $notify;

    foreach my $e ( @$E ) {
        DEBUG and warn "$self->{alias}: inotify ", $e->fullname;
        foreach my $call ( @{ $notify->{call} } ) {
            DEBUG and do {
                warn sprintf "$self->{alias}: %08x vs %08x", $e->mask, $call->{tmask};
                foreach my $flag ( qw( ACCESS MODIFY ATTRIB CLOSE_WRITE CLOSE_NOWRITE 
                       OPEN MOVED_FROM MOVED_TO CREATE DELETE DELETE_SELF
                       MOVE_SELF ALL_EVENTS ONESHOT ONLYDIR DONT_FOLLOW
                       MASK_ADD CLOSE MOVE ) ) {
                    my $method = "IN_$flag";
                    warn "$self->{alias}: $flag" if $e->$method();
                }
            };
            
            next unless $e->mask & $call->{tmask};

            my $CB = dclone $call->{cb};
            $CB->[2] = $e;
            poe->kernel->call( @$CB );
        }
    }
}

#############################################
sub _find_path
{
    my( $self, $path ) = @_;
    return $self->{path}{ $path };
}


sub _build_call
{
    my( $self, $args ) = @_;
    my $event = $args->{event};
    return "No event specified" unless $event;

    my $A     = $args->{args};
    my $session = poe->sender;

    my $call = [ $session, $event, undef ];
    if( $A ) {
        $A = dclone $A if ref $A;
        if( 'ARRAY' eq ref $A ) {
            push @$call, @$A;
        }
        else {
            push @$call, $A;
        }
    }

    return { cb   => $call, 
             mask => $args->{mask},                     # user specified mask
             tmask => $self->_const2mask( $args ),      # true mask
           };
}

sub _const2mask
{
    my( $self, $args ) = @_;
    my $mask = $args->{mask}; 
    if( -f $args->{path} and $mask | IN_DELETE ) {
        $mask |= IN_DELETE_SELF;    # IN_DELETE is useless on a file
    }
    return $mask;
}

#############################################
sub monitor
{
    my( $self, $args ) = @_;
    return if $self->{shutdown};

    my $path = $args->{path};
    my $caller = join ' ', at => poe->caller_file,
                               line => poe->caller_line;
    $args->{mask} = IN_ALL_EVENTS unless defined $args->{mask};

    my $notify = $self->_find_path( $path );
    my $in_mask = $args->{mask};
    if( $notify ) {
        $in_mask |= $notify->{mask};
    }

    my $watch = $self->add_inotify( $path, $in_mask );

    my $call = $self->_build_call( $args, $watch );
    die "Unable to build call: $call $caller" unless ref $call;

    if( $notify ) {
        DEBUG and warn "$self->{alias}: monitor $path again";
        push @{ $notify->{call} }, $call;
        $notify->{watch} = $watch;
    }
    else {
        DEBUG and warn "$self->{alias}: monitor $path";

        unless( $watch ) {
            die "Unable to watch $path: $! $caller";
        }

        $notify = {
                    path => $path,
                    call => [ $call ],
                    mask => $args->{mask},
                    watch => $watch
                };
        $self->{path}{$path} = $notify;
        poe->kernel->refcount_increment( poe->session->ID, "NOTIFY $path" );
    }

    poe->kernel->refcount_increment( poe->sender, "NOTIFY $path" );

    return;
}

sub unmonitor
{
    my( $self, $args ) = @_;
    my $path = $args->{path};
    $args->{mask} = 0xFFFFFFFF unless defined $args->{mask};
    $args->{session} = poe->sender;
    my $caller = join ' ', at => poe->caller_file,
                               line => poe->caller_line;
    my $notify = $self->_find_path( $path );
    unless( $notify ) {
        warn "$path wasn't monitored $caller\n";
        return;
    }
    my $changed = 0;
    my @calls;
    foreach my $call ( @{ $notify->{call} } ) {
        if( $self->_call_match( $call, $args ) ) {
            poe->kernel->refcount_decrement( $args->{session}, "NOTIFY $path" );
            $changed = 1;
        }
        else {
            push @calls, $call;
        }
    }
    $notify->{call} = \@calls;
    if( @calls ) {
        if( $changed ) {
            $notify->{mask} = $self->_notify_mask( $notify );
            $self->add_inotify( $path, $notify->{mask} );
        }
        
        DEBUG and warn "$path still being monitored\n";
    }
    else {
        DEBUG and warn "$self->{alias}: unmonitor $path";
        $notify->{watch}->cancel; 
        poe->kernel->refcount_decrement( poe->session->ID, "NOTIFY $path" );
        delete $self->{path}{ $path };
    }
    return;
}

sub _call_match
{
    my( $self, $call, $args ) = @_;
    return 1 if $self->{force};
    return unless $call->{cb}[0] eq $args->{session};
#    return unless $call->{mask} == $args->{mask};
    return 1 unless $args->{event};
    return 1 if $args->{event} eq '*';
    return 1 if $call->{cb}[1] eq $args->{event};
    return;
}


sub _notify_mask
{
    my( $self, $notify ) = @_;
    my $mask = 0;
    foreach my $call ( @{ $notify->{call} } ) {
        $mask |= $call->{mask};
    }
    return $mask;
}

1;


__END__

=head1 NAME

POEx::Inotify - inotify interface for POE

=head1 SYNOPSIS

    use strict;

    use POE;
    use POEx::Inotify;

    POEx::Inotify->new( alias=>'notify' );

    POE::Session->create(
        package_states => [ 
                'main' => [ qw(_start notification) ],
        ],
    );

    $poe_kernel->run();
    exit 0;

    sub _start {
        my( $kernel, $heap ) = @_[ KERNEL, HEAP ];

        $kernel->post( 'notify' => monitor => {
                path => '.',
                mask  => IN_CLOSE_WRITE,
                event => 'notification',
                args => [ $args ]
             } );
        return;  
    }

    sub notification {
        my( $kernel, $e, $args ) = @_[ KERNEL, ARG0, ARG1];
        print "File ready: ", $e->fullname, "\n";
        $kernel->post( notify => 'shutdown' );
        return;
    }

=head1 DESCRIPTION

POEx::Inotify is a simple interface to the Linux file and directory change
notification interface, also called C<inotify>.

It can monitor an existing directory for new files, deleted files, new
directories and more.  It can monitor an existing file to see if it changes,
is deleted or moved.

=head1 METHODS

=head2 spawn

    POEx::Inotify->spawn( %options );

Creates the C<POEx::Inotify> session.  It takes a number of arguments, all
of which are optional.

=over 4

=item alias

The session alias to register with the kernel.  Defaults to C<inotify>.

=item options

A hashref of POE::Session options that are passed to the component's 
session creator.

=back




=head1 EVENTS

=head2 monitor

    $poe_kernel->call( inotify => 'monitor', $arg );

Starts monitoring the specified path for the specified types of changes.

Accepts one argument, a hashref containing the following keys: 

=over 4

=item path

The filesystem path to the directory to be monitored.  Mandatory.

=item mask

A mask of events that you wish to monitor.  May be any of the following constants
(exported by L<Linux::Inotify2>) ORed together.  Defaults to C<IN_ALL_EVENTS>.

=back

=over 8

=item IN_ACCESS

object was accessed

=item IN_MODIFY

object was modified

=item IN_ATTRIB

object metadata changed

=item IN_CLOSE_WRITE

writable fd to file / to object was closed

=item IN_CLOSE_NOWRITE

readonly fd to file / to object closed

=item IN_OPEN

object was opened

=item IN_MOVED_FROM

file was moved from this object (directory)

=item IN_MOVED_TO

file was moved to this object (directory)

=item IN_CREATE

file was created in this object (directory)

=item IN_DELETE

file was deleted from this object (directory)

=item IN_DELETE_SELF

object itself was deleted

=item IN_MOVE_SELF

object itself was moved

=item IN_ALL_EVENTS

all of the above events


=item IN_ONESHOT

only send event once

=item IN_ONLYDIR

only watch the path if it is a directory

=item IN_DONT_FOLLOW

don't follow a sym link

=item IN_MASK_ADD

not supported with the current version of this module

=item IN_CLOSE

same as IN_CLOSE_WRITE | IN_CLOSE_NOWRITE

=item IN_MOVE

same as IN_MOVED_FROM | IN_MOVED_TO

=back

=over 4

=item event

The name of the event handler in the current session to post changes back
to.  Mandatory.

The event handler will receive an L<Linux::Inotify2::Event> as its first argument.  Other
arguments are those specified by L</args>.

=item args

An arrayref of arguments that will be passed to the event handler.

=back


=head3 Example

    use Linux::Inotify2;

    my $dir = '/var/ftp/incoming';

    my $arg = {
            path => $path
            mask => IN_DELETE|IN_CLOSE,
            event => 'uploaded',
            args  => [ $dir ]
        };
    $poe_kernel->call( inotify => 'monitor', $arg );

    sub uploaded 
    {
        my( $e, $path ) = @_[ARG0, ARG1];
        warn $e->fullname, " was uploaded to $path";
    }

=head2 unmonitor

    $poe_kernel->call( inotify => 'unmonitor', $arg );

Ends monitoring of the specified path for the current session.

Accepts one argument, a hashref containing the following keys: 

=over 4

=item path

The filesystem path to the directory to to stop monitoring.  Mandatory.

=item event

Name of the monitor event that was used in the original L</monitor> call.  Mandatory.
You may use C<*> to unmonitor all events for the current session.

=back

=head3 Note

Multiple sessions may monitor the same path at the same time.  A single
session may monitor multiple paths.  However, if a single session is
monitoring the same path multiple times it must use different events
to distinguish them.


=head2 shutdown

    $poe_kernel->call( inotify => 'shutdown' );
    # OR
    $poe_kernel->signal( $poe_kernel => 'shutdown' );
 
Shuts down the component gracefully. All monitored paths will be closed. Has
no arguments.


=head1 SEE ALSO

L<POE>, L<Linux::Inotify2>.

This module's API was heavily inspired by
L<POE::Component::Win32::ChangeNotify>.

=head1 AUTHOR

Philip Gwyn, E<lt>gwyn -at- cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Philip Gwyn.  All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.


=cut
