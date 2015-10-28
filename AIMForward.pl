# Pidgin Perl Plugin to forward specific AIM messages to a socket on a remote server
# Developed by Oliver Saunders (o.saunders at me.com)

package AIMForward;

use strict;
use warnings;
use diagnostics;

use Purple; # Pidgin / libpurple API
use IO::Socket; # OO sockets library
use File::HomeDir; # Allows us to get the directory to write the log to

my $plugin; # Reference to loaded plugin

# Constants for sockets and messages
my $destinationSocket;
my $AF_EXPECTED_SENDER = 'OMCS'; 
my $AF_REMOTE_HOST = '10.0.2.2';
my $AF_REMOTE_PORT = '11102';
my $AF_MSG_PROTOCOL = 'prpl-aim';
my $AF_FORMAT_STR = 'XE|4999|0326A573-A5AB-C28F-C565-A102303040DF3|'; # %s|%s\n
my $FATAL_CONNECTION_ERROR = -1;
my $TMPRY_CONNECTION_ERROR = -2;

# Enable or disable logging to a text file
my $SEPARATOR = '\\'; # Separator for Windows, change this to '/' on UNIX
my $ENABLE_LOGGING = 1;
my $LOG_PATH = File::HomeDir->my_home . $SEPARATOR . "AIMForward.log";
my $logFile = undef;
my $logOpen = 0; 

# Information for the Pidgin plugin UI, globally accessible
our %PLUGIN_INFO = 
(
    perl_api_version => 2,
    name => "AIMForward",
    version => "1.1",
    summary => "Forwards certain AIM messages to a remote socket.",
    description => "This plugin forwards AIM messages matching a specific pattern to a socket on a remote server.",
    author => "Oliver Saunders <o.saunders at me.com>",
    url => "www.github.com/OMCS",
    load => "plugin_load",
    unload => "plugin_unload"
);

# This function is called when the plugin is probed by Pidgin, even if it isn't loaded
sub plugin_init 
{
    # Return information to show in the plugin dialog
    return %PLUGIN_INFO;
}

# This function is called when the plugin is loaded
sub plugin_load 
{
    $plugin = shift;

    Purple::Debug::info("AIMForward", "plugin_load() - AIMForward Initialized.\n");

    # Connect to the conversation list exposed by libpurple
    my $conversations = Purple::Conversations::get_handle();

    # Connect the conv_received_msg function to the received-im-msg signal, this function will be called whenever new messages come in
    Purple::Signal::connect($conversations, "received-im-msg", $plugin, \&conv_received_msg, "received im message");

    # Attempt to open the socket on the remote computer
    setup_socket();

    return;
}

# Called whenever the plugin is unloaded
sub plugin_unload 
{
    # Close the log file if we are using one
    if ($logOpen)
    {
        close $logFile;
    }

    if ($destinationSocket)
    {
        # Close the connection to the remote socket
        shutdown($destinationSocket, 1);
    }

    Purple::Debug::info("AIMForward", "plugin_unload() - AIMForward Terminated.\n");

    return;
}

# Utility function for writing to a debug log file, used for recording incoming information, results of parsing and information sent to the server
sub log_to_file
{
    # Only continue if logging is enabled
    if ($ENABLE_LOGGING)
    {
        my $logMessage = shift;
        my $timestamp = localtime(time);

        if (!$logOpen)
        {
            # Attempt to open the log file in append mode
            ## no critic qw(RequireBriefOpen)
            if (open $logFile, '>>', $LOG_PATH)
            {
                $logFile->autoflush(1); # Disable buffering
                $logOpen = 1;
            }

            else
            {
                Purple::Debug::error("AIMForward", "Failed to open log file.");
            }

        }

        # Write message to log with timestamp
        print $logFile "$timestamp: AIMForward, $logMessage\n"; 
    }

    return;
}

# Function which sets up a connection to the remote socket, used when plugin is loaded to ensure server can be reached
sub setup_socket()
{
    Purple::Debug::info("AIMForward", "Attempting to connect to " . $AF_REMOTE_HOST . " on port " . $AF_REMOTE_PORT . "...\n");

    # Instantiate a new INET socket object which connects as soon as it is created
    $destinationSocket = IO::Socket::INET->new
    (
        PeerHost => $AF_REMOTE_HOST,
        PeerPort => $AF_REMOTE_PORT,
        Proto => 'tcp',
        Timeout => 2,
    );

    # Ensure connection is working
    if (!$destinationSocket)
    {
        handle_connection_error($FATAL_CONNECTION_ERROR);
    }

    Purple::Debug::info("AIMForward", "Connection to $AF_REMOTE_HOST on port $AF_REMOTE_PORT successful.\n");

    # Can close once connection parameters have been verified
    close($destinationSocket);

    return;
}

# Forward the message passed as an argument to the remote socket
sub forward_to_socket
{
    $destinationSocket = IO::Socket::INET->new
    (
        PeerHost => $AF_REMOTE_HOST,
        PeerPort => $AF_REMOTE_PORT,
        Proto => 'tcp',
    );

    # Ensure connection is working
    if ($destinationSocket)
    {
        # Send the processed message to the socket and then close the connection 
        my $message = shift;
        $destinationSocket->send($message);
        close($destinationSocket);

        Purple::Debug::info("AIMForward", "Message successfully sent to $AF_REMOTE_HOST:$AF_REMOTE_PORT\n");
    }

    else
    {
        handle_connection_error($TMPRY_CONNECTION_ERROR);
    }

    return;
}

sub handle_connection_error
{
    my $error = shift;

    # If the error is temporary, write to the log file
    if ($error == $TMPRY_CONNECTION_ERROR)
    {
        Purple::Notify::message($plugin, $Purple::Notify::Msg::WARNING, "AimForward", "Temporary Error", "The remote socket could not be reached, check your network settings.", undef, undef);
        Purple::Debug::warning("AIMForward", "Temporary error connecting to remote socket, check your network settings.");
    }

    else
    {
        # If there is a problem connecting to the server initially, the plugin will unload itself after presenting an error message and writing a message to the debug log
        Purple::Debug::error("AIMForward", "Error connecting to server, check address and port number.\n");    
        Purple::Notify::message($plugin, $Purple::Notify::Msg::ERROR, "AimForward", "Network Error", "Error connecting to remote socket, wrong hostname or port? Plugin terminating.", undef, undef);
        die; 
    }

    return;
}

# This function takes a message, parses it and prepares it for sending
sub parse_msg
{
    my $message = shift;
    Purple::Debug::info("AIMForward", "Original Message: $message\n");

    ($message) = $message =~ /!\?\s?(.*?)\s?!\?$/gx; # Extract only the data between the delimiters
    $message =~ s/,/./gx; # Replace all commas with periods
    $message =~ s/!\?//gx; # Remove the delimiters, these do not need to be sent to the server

    # Extract the symbol, which is located between the first and second periods in the modified message string
    push(my @values, split(/\./x, $message));
    my $symbol = $values[1];
    
    # Insert parsed message into the required format string to send to the remote socket
    # XE|4999|0326A573-A5AB-C28F-C565-A102303040DF3| %s|%s\n
    my $parsedMessage = $AF_FORMAT_STR . $symbol . "|" . $message . "\n";

    Purple::Debug::info("AIMForward", "Parsed Message: $parsedMessage");
    log_to_file("Parsed Message Sent to Server: " . $parsedMessage);

    return $parsedMessage;
}

# This function will be called whenever a message is received
sub conv_received_msg
{
    # Access variables passed in from signal
    my ($account, $sender, $message) = @_;

    # Check if the message received is using the AIM protocol and sent by the expected sender 
    if ($account->get_protocol_id() eq $AF_MSG_PROTOCOL && $sender eq $AF_EXPECTED_SENDER)
    {
        # Strip all HTML tags
        $message = Purple::Util::Markup::strip_html($message);

        # Check if the message contains a substring which begins and ends with '!?' and continues until the end of the message
        # These are what we are interested in forwarding
        if ($message =~ /!\?\s?(.*?)\s?!\?$/gx) 
        {
            # Call the forward_to_socket function with the output of parse_msg which correctly formats the data
            # it will be sent to the remote socket after formatting
            log_to_file("Message Received: " . $message); 
            forward_to_socket(parse_msg($message));   
        }

        else
        {
            log_to_file("Message Ignored: " . $message);
        }
    }

    return;
}

1;
