   use Gtk2 -init;
   use AnyEvent;

   ############################################
   # create a window and some label

   my $window = new Gtk2::Window "toplevel";
   $window->add (my $label = new Gtk2::Label "soon replaced by name");

   $window->show_all;

   ############################################
   # do our AnyEvent stuff

   $| = 1; print "enter your name> ";

   my $name_ready = AnyEvent->condvar;

   my $wait_for_input = AnyEvent->io (
      fh => \*STDIN, poll => "r",
      cb => sub {
         # set the label
         $label->set_text (scalar <STDIN>);
         print "enter another name> ";
      }
   );

   ############################################
   # Now enter Gtk2's event loop

   main Gtk2;