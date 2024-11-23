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

My intention is that this module be free for anyone to use, as long as they
share any modifications they make. However, I'm confused about how licenses like
the GPL and AGPL apply to infrastructure specifications like NixOS modules, e.g.
whether using this module to host a Friendica instance would require someone to
make available their changes to the module.

See also: https://discourse.nixos.org/t/how-do-folks-think-about-licenses-for-nix-code-nixos-modules/56469

For the time being, therefore, there's no explicit license grant. If you're
accessing this repository through GitHub, you're granted certain rights e.g. to
read and fork the repo under their terms of service:
https://docs.github.com/en/site-policy/github-terms/github-terms-of-service#5-license-grant-to-other-users

You can also (obviously) use this repo in any way that doesn't require
permission from copyright owners, e.g. under fair use.

Feel free to contact me (e.g. open an issue) to propose something else, if you
have a use case for it.
