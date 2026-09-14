# Installing AiresDB

Welcome! AiresDB currently requires **Julia 1.12**, and supported user access
goes through AiresDB TinyServer. The recommended installation creates the
`airesdb` command so you can start the server and CLI monitor directly.

## 1. Check Julia

Run:

```text
julia --version
```

The output should begin with `julia version 1.12`. If the command is missing or
the version is different, install Julia 1.12 using the
[official Julia installation guide](https://julialang.org/install/).

## 2. Install the CLI app from GitHub

AiresDB is not yet available from Julia's General registry. Use the GitHub URL
for the current installation. The command bootstraps the default General
registry only when a fresh Julia installation has no reachable registry. The
repository URL is passed as a Julia argument, avoiding nested quote escaping.

### Linux, macOS, or a Unix shell

```sh
julia -e 'using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.Apps.add(url=ARGS[1])' https://github.com/aires-id/AiresDB
```

### Windows PowerShell

```powershell
julia -e 'using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.Apps.add(url=ARGS[1])' https://github.com/aires-id/AiresDB
```

### Windows Command Prompt (`cmd.exe`)

```bat
julia -e "using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.Apps.add(url=ARGS[1])" https://github.com/aires-id/AiresDB
```

> [!NOTE]
> PowerShell uses outer single quotes; Command Prompt uses outer double quotes.
> Do not copy the Unix or PowerShell form into Command Prompt. That shell does
> not use single quotes for argument grouping and Julia reports `character
> literal contains multiple characters`.

> [!NOTE]
> A cold first installation can take a few minutes while Julia downloads and
> precompiles dependencies. Please leave the terminal open until it reports
> that the `airesdb` app was installed.

`Pkg.Apps.add` installs AiresDB in a Julia app environment and creates an
`airesdb` launcher in the Julia app directory.

## 3. Add the app directory to `PATH`

If `airesdb` is not immediately recognized, add the Julia app directory to the
current terminal session.

### Linux or macOS

```sh
export PATH="$HOME/.julia/bin:$PATH"
```

### Windows PowerShell

```powershell
$env:Path += ";$HOME\.julia\bin"
```

### Windows Command Prompt

```bat
set "PATH=%PATH%;%USERPROFILE%\.julia\bin"
```

These commands affect only the current terminal. You may add the same directory
to your shell profile or user environment variables later for a permanent setup.

## 4. Verify the installation and version

Check the launcher:

```text
airesdb --help
```

List installed Julia apps on Linux, macOS, or PowerShell:

```sh
julia -e 'using Pkg; Pkg.Apps.status()'
```

In Command Prompt, use:

```bat
julia -e "using Pkg; Pkg.Apps.status()"
```

The status output should include `AiresDB v0.1.0` and the `airesdb` app.

## 5. Start the server

In the first terminal, run:

```text
airesdb server
```

The first start asks you to create and confirm the `root` password. Keep this
terminal open. TinyServer listens on `127.0.0.1:1972` by default.

In a second terminal, verify that the server is ready:

```text
curl http://127.0.0.1:1972/health
```

The response is `{"ok":true,"server":"AiresDB","version":"0.1.0"}`.
In PowerShell, `Invoke-RestMethod http://127.0.0.1:1972/health` is equivalent.

## 6. Open the CLI monitor

In a second terminal, run:

```text
airesdb -u root -p
```

Enter the password created by the server. When the `AiresDB [(none)]>` prompt
appears, you can enter AiresQL:

```text
Buat 'Demo' -:
Pilih 'Demo' -:
.current
.exit
```

The `-p` option asks for the password securely. It does not take the password as
the next command-line argument.

## Updating the app

To update a GitHub installation on Linux or macOS, run:

```sh
julia -e 'using Pkg; Pkg.Apps.update()'
```

In Windows PowerShell, run:

```powershell
julia -e 'using Pkg; Pkg.Apps.update()'
```

In Command Prompt, run:

```bat
julia -e "using Pkg; Pkg.Apps.update()"
```

Run `Pkg.Apps.status()` again to confirm the installed revision and version.

> [!NOTE]
> Julia's app support is experimental in Julia 1.12. The launcher uses the Julia
> executable that installed it. Reinstall the app if that Julia executable is
> moved or removed.

## Package-only installation

Use this option when you want AiresDB in the active Julia environment without
installing the standalone app launcher.

### Linux, macOS, or a Unix shell

```sh
julia -e 'using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.add(url=ARGS[1])' https://github.com/aires-id/AiresDB
```

### Windows PowerShell

```powershell
julia -e 'using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.add(url=ARGS[1])' https://github.com/aires-id/AiresDB
```

### Windows Command Prompt

```bat
julia -e "using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.add(url=ARGS[1])" https://github.com/aires-id/AiresDB
```

From that Julia environment, use the module entry point:

```text
julia -m AiresDB server
julia -m AiresDB -u root -p
```

The `-e` flag evaluates Julia code. It is not an AiresDB launcher, so
`julia -e airesdb -u root -p` is not valid syntax.

## Future General registry installation

After AiresDB is accepted into Julia's General registry, the app installation
on Linux or macOS will become:

```sh
julia -e 'using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.Apps.add(ARGS[1])' AiresDB
```

PowerShell will use:

```powershell
julia -e 'using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.Apps.add(ARGS[1])' AiresDB
```

Command Prompt will use:

```bat
julia -e "using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.Apps.add(ARGS[1])" AiresDB
```

The equivalent package-only command will be `julia -e 'using Pkg;
Pkg.add(ARGS[1])' AiresDB` in a Unix shell or PowerShell (use outer double
quotes around the Julia code in Command Prompt). These package-name-only
commands are documented for the future and are not the current installation
path.

## Development from a checkout

After cloning this repository, run these commands from its root directory:

```sh
julia --project=. -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
julia --project=. -e "using Pkg; Pkg.test()"
```

Start the server and client from the checkout:

```text
julia --project=. -m AiresDB server
julia --project=. -m AiresDB -u root -p
```

An equivalent development launcher is available at `bin/airesdb.jl`. The
project also declares the `airesdb` Julia 1.12 app in `Project.toml`.

## Troubleshooting

### `character literal contains multiple characters`

You probably copied the Unix command into Windows Command Prompt. Use the
PowerShell or Command Prompt command shown above with that shell's outer quotes.

### `airesdb` is not recognized

Add `~/.julia/bin` to `PATH` using the command for your terminal, then run
`airesdb --help` again. On Windows, the launcher is named `airesdb.bat`.

### The CLI reports a connection error

Start `airesdb server` in the first terminal and leave it running before opening
`airesdb -u root -p` in the second terminal. The supported client does not open
`.aires` files directly when TinyServer is unavailable.

### Login is denied

Use the `root` password created during the server's first start. Restarting the
client does not reset that password or bypass the login lockout.

The maintainer checklist for publishing to General is available in
[docs/REGISTRATION.md](docs/REGISTRATION.md).
