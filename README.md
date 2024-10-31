# friendica module for NixOS

I don't recommend using this as-is, but you're welcome to read it for ideas or
to see how I solved a particular problem. Hopefully it should be pretty
well-commented.

Why not use it? Well, I've tested that I can post on it using my admin account,
but I've not used it seriously "in anger", so I can't guarantee other
functionality is there. More importantly, my experience is that it seems pretty
easy to accidentally introduce security vulnerabilities into the deployment.
I'm most concerned by the possibility of accidentally disclosing code or private
data files (e.g. the config file) by getting the Apache config wrong, but I
don't want to rule out other potential problems I could have introduced. The
fact that the core Friendica code is in the Nix store and thus not writeable is
helpful, but unfortunately there are things like the smarty3 cache that demand
to be writeable by the server user.

There are a few measures I could take to improve this situation, my favourite
being insisting on use of php-fpm and a chroot environment so that running PHP
processes can't access most of the filesystem. Also, if you feel qualified to
review or pentest the code to the point where you feel comfortable with it, go
right ahead. But I don't think I can endorse it in its current state.

## License

I'll pick one shortly. I realise the code is close to useless until I do.
