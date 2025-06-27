# `pgagroal-cli` user guide

`pgagroal-cli` is a command line interface to interact with [**pgagroal**](https://github.com/agroal/pgagroal).
The executable accepts a set of options, as well as a command to execute.
If no command is provided, the program will show the help screen.

The `pgagroal-cli` utility has the following synopsis:

```
pgagroal-cli [ OPTIONS ] [ COMMAND ]
```


## Options

Available options are the following ones:

```
-c, --config CONFIG_FILE Set the path to the pgagroal.conf file
-h, --host HOST          Set the host name
-p, --port PORT          Set the port number
-U, --user USERNAME      Set the user name
-P, --password PASSWORD  Set the password
-L, --logfile FILE       Set the log file
-F, --format  text|json  Set the output format
-v, --verbose            Output text string of result
-V, --version            Display version information
-?, --help               Display help

```

Options can be specified either in short or long form, in any position of the command line.

By default the command output, if any, is reported as text. It is possible to specify JSON as the output format,
and this is the suggested format if there is the need to automtically parse the command output, since the text format
could be subject to changes in future releases. For more information about the JSON output format,
please see the [JSON Output Format](#json-output-format) section.

## Commands

### flush
The `flush` command performs a connection flushing.
It accepts a *mode* to operate the actual flushing:
- `gracefully` (the default if not specified), flush connections when possible;
- `idle` to flush only connections in state *idle*;
- `all` to flush all the connections (**use with caution!**).

The command accepts a database name, that if provided, restricts the scope of
`flush` only to connections related to such database.
If no database is provided, the `flush` command is operated against all databases.


Command

```
pgagroal-cli flush [gracefully|idle|all] [*|<database>]
```

Examples

```
pgagroal-cli flush           # pgagroal-cli flush gracefully '*'
pgagroal-cli flush idle      # pgagroal-cli flush idle '*'
pgagroal-cli flush all       # pgagroal-cli flush all '*'
pgagroal-cli flush pgbench   # pgagroal-cli flush gracefully pgbench
```

### ping
The `ping` command checks if [**pgagroal**](https://github.com/agroal/pgagroal) is running.
In case of success, the command does not print anything on the standard output unless the `--verbose` flag is used.

Command

```
pgagroal-cli ping
```

Example

```
pgagroal-cli ping --verbose  # pgagroal-cli: Success (0)
pgagroal-cli ping            # $? = 0
```

In the case [**pgagroal**](https://github.com/agroal/pgagroal) is not running, a message is printed on the standard error and the exit status is set to a non-zero value:

```
pgagroal-cli ping          # $? = 1
Connection error on /tmp
```

### enable
Enables a database (or all databases).

Command

```
pgagroal-cli enable [<database>|*]
```

Example

```
pgagroal-cli enable
```

### disable
Disables a database (or all databases).

Command

```
pgagroal-cli disable [<database>|*]
```

Example

```
pgagroal-cli disable
```

### shutdown
The `shutdown` command is used to stop the connection pooler.
It supports the following operating modes:
- `gracefully` (the default) closes the pooler as soon as no active connections are running;
- `immediate` force an immediate stop.

If the `gracefully` mode is requested, chances are the system will take some time to
perform the effective shutdown, and therefore it is possible to abort the request
issuing another `shutdown` command with the mode `cancel`.


Command

```
pgagroal-cli shutdown [gracefully|immediate|cancel]
```

Examples

```
pgagroal-cli shutdown   # pgagroal-cli shutdown gracefully
...
pgagroal-cli shutdown cancel  # stops the above command
```


### status
The `status` command reports the current status of the [**pgagroal**](https://github.com/agroal/pgagroal) pooler.
Without any subcommand, `status` reports back a short set of information about the pooler.

Command

```
pgagroal-cli status
```

Example

```
pgagroal-cli status

```

With the `details` subcommand, a more verbose output is printed with a detail about every connection.

Example

```
pgagroal-cli status details
```

### switch-to
Switch to another primary server.

Command

```
pgagroal-cli switch-to <server>
```

Example

```
pgagroal-cli switch-to replica
```

### conf
Manages the configuration of the running instance.
This command requires one subcommand, that can be:
- `reload` issue a reload of the configuration, applying at runtime any changes from the configuration files;
- `get` provides a configuration parameter value;
- `set` modifies a configuration parameter at runtime;
- `ls` prints where the configuration files are located.

Command

```
pgagroal-cli conf <what>
```

Examples

```
pgagroal-cli conf reload

pgagroal-cli conf get max_connections

pgagroal-cli conf set max_connections 25

```

The details about how to get and set values at run-time are explained in the following.

#### conf get

The `conf get` command retrieves the current value of a configuration parameter from the running instance.

**Syntax:**
```
pgagroal-cli conf get <parameter_name> [--verbose] [--format json]
```

**Parameter Name Format:**
The parameter name can be specified in several forms using dot notation:
- `key`: Refers to a global configuration parameter (e.g., `log_level`)
- `section.key`: Refers to a parameter within a named section (e.g., `server.venkman.port`)
- `section.context.key`: Refers to a parameter within a context, such as a limit or HBA entry (e.g., `limit.pgbench.max_size`, `hba.myuser.method`)

**Supported Namespaces:**
- `pgagroal` (optional): Main configuration namespace, e.g., `pgagroal.log_level` or simply `log_level`
- `server`: Refers to a specific server, e.g., `server.venkman.port`
- `limit`: Refers to a specific limit entry, e.g., `limit.pgbench.max_size`
- `hba`: Refers to a specific HBA entry, e.g., `hba.myuser.method`

**Context Rules:**
- For `limit`, the context is the database name as found in `pgagroal_databases.conf`.
- For `hba`, the context is the username as found in `pgagroal_hba.conf`.
- For `server`, the context is the server name as found in `pgagroal.conf`.
- For `pgagroal`, the context must be empty.

> **Important:**  
> If there are multiple entries with the same database name in the `limit` section or the same username in the `hba` section, **the last matching entry in the configuration file is used** for `conf get`.

---

**Examples:**
```
pgagroal-cli conf get pipeline
performance

pgagroal-cli conf get limit.pgbench.max_size
2

pgagroal-cli conf get server.venkman.primary
off

pgagroal-cli conf get hba.myuser.method
scram-sha-256
```

In the above examples:
- `pipeline` is equivalent to `pgagroal.pipeline` and retrieves a global configuration setting.
- `limit.pgbench.max_size` retrieves the `max_size` for the `pgbench` database from the *last* matching entry in `pgagroal_databases.conf`.
- `server.venkman.primary` retrieves the `primary` parameter from the server section named `venkman` in `pgagroal.conf`.
- `hba.myuser.method` retrieves the authentication method for `myuser` from the *last* matching entry in `pgagroal_hba.conf`.

---

**Verbose Output:**
If the `--verbose` option is specified, the output is more descriptive:
```
pgagroal-cli conf get max_connections --verbose
max_connections = 4
Success (0)
```

**Behavior:**
- If the parameter is found, its value is printed.
- If the parameter is not found or invalid, no output is printed and the exit code is non-zero.

---

**Full Configuration Output:**

If you run the `conf get` command without specifying any parameter name, the command will return the complete configuration, including all main settings, servers, limits, and HBA entries.

```
pgagroal-cli conf get
```

You can also retrieve a specific section by specifying only the section name:

- To get all limit entries:
  ```
  pgagroal-cli conf get limit
  ```
- To get all HBA entries:
  ```
  pgagroal-cli conf get hba
  ```
- To get all Server entries:
  ```
  pgagroal-cli conf get server
  ```

> **Important:**  
> When viewing the full configuration or a section (such as `limit` or `hba`), **only a single entry will be present for each database name in `limit` and for each username in `hba`**.  
> If your configuration file contains multiple entries with the same database name (in `limit`) or the same username (in `hba`), **only the last entry in the configuration file will be shown**.   
> Always ensure your configuration files are ordered as intended, since only the last occurrence for each key is included in response of `conf get`.

This behavior is important to consider when managing or troubleshooting your configuration.

**Note:**  
The configuration key must match the format and naming used in the configuration files. For more details on available parameters and their structure, see the [Configuration documentation](./CONFIGURATION.md).



#### conf set
Allows the setting of a configuration parameter at run-time, if possible.

Examples
```
pgagroal-cli conf set log_level debug
pgagroal-cli conf set server.venkman.port 6432
pgagroal conf set limit.pgbench.max_size 2
```

The syntax for setting parameters is the same as for the command `conf get`, therefore parameters are organized into namespaces:
- `main` (optional) is the main pgagroal configuration namespace, for example `main.log_level` or simply `log_level`;
- `server` is the namespace referred to a specific server. It has to be followed by the name of the server and the name of the parameter to change, in a dotted notation, like `server.venkman.port`;
- `limit` is the namespace referred to a specific limit entry, followed by the name of the username used in the limit entry.

When executed, the `conf set` command returns the run-time setting of the specified parameter: if such parameter is equal to the value supplied, the change has been applied, otherwise it means that the old setting has been kept.
The `--verbose` flag can be used to understand if the change has been applied:

```
$ pgagroal-cli conf set log_level debug
debug

$ pgagroal-cli conf set log_level debug --verbose
log_level = debug
pgagroal-cli: Success (0)
```

When a setting modification cannot be applied, the system returns the "old" setting value and, if `--verbose` is specified, the error indication:

```
$ pgagroal-cli conf set max_connections 100
40

$ pgagroal-cli conf set max_connections 100 --verbose
max_connections = 40
pgagroal-cli: Error (2)
```

When a `conf set` cannot be applied, the system will report in the logs an indication about the problem. With regard to the previous example, the system reports in the logs something like the following (depending on your `log_level`):

```
DEBUG Trying to change main configuration setting <max_connections> to <100>
INFO  Restart required for max_connections - Existing 40 New 100
WARN  1 settings cannot be applied
DEBUG pgagroal_management_write_config_set: unable to apply changes to <max_connections> -> <100>
```

#### conf ls

The command `conf ls` provides information about the location of the configuration files.
As an example:

```
Main Configuration file:   /etc/pgagroal/pgagroal.conf
HBA file:                  /etc/pgagroal/pgagroal_hba.conf
Limit file:                /etc/pgagroal/pgagroal_databases.conf
Frontend users file:       /etc/pgagroal/pgagroal_frontend_users.conf
Admins file:               /etc/pgagroal/pgagroal_admins.conf
Superuser file:
Users file:                /etc/pgagroal/pgagroal_users.conf
```

### clear
Resets different parts of the pooler. It accepts an operational mode:
- `prometheus` resets the metrics provided without altering the pooler status;
- `server` resets the specified server status.


```
pgagroal-cli clear [prometheus|server <server>]
```

Examples

```
pgagroal-cli clear spengler            # pgagroal-cli clear server spengler
pgagroal-cli clear prometheus
```


## Shell completions

There is a minimal shell completion support for `pgagroal-cli`.
Please refer to the [Install pgagroal](https://github.com/agroal/pgagroal/blob/master/doc/tutorial/01_install.md) tutorial for detailed information about how to enable and use shell completions.


## JSON Output Format

It is possible to obtain the output of a command in a JSON format by specyfing the `-F` (`--format`) option on the command line.
Supported output formats are:
- `text` (the default)
- `json`

As an example, the following are invocations of commands with different output formats:

```
pgagroal-cli status     # defaults to text output format

pgagroal-cli status --format text  # same as above
pgagroal-cli status -F text        # same as above

pgagroal-cli status --format json  # outputs as JSON text
pgagroal-cli status -F json        # same as above
```

Whenever a command produces output, the latter can be obtained in a JSON format.
Every command output consists of an object that contains two other objects:
- a `command` object, with all the details about the command and its output;
- an `application` object, with all the details about the executable that launched the command (e.g., `pgagroal-cli`).

In the following, details about every object are provided:

### The `application` object

The `application` object is made by the following attributes:
- `name` a string representing the name of the executable that launched the command;
- `version` a string representing the version of the executable;
- `major`, `minor`, `patch` are integers representing every single part of the version of the application.

As an example, when `pgagroal-cli` launches a command, the output includes an `application` object like the following:

```
 "application":  {
                "name": "pgagroal-cli",
                "major":        1,
                "minor":        6,
                "patch":        0,
                "version":      "1.6.0"
        }
```


### The `command` object

The `command` object represents the launched command and contains also the answer from the [**pgagroal**](https://github.com/agroal/pgagroal).
The object is made by the following attributes:
- `name` a string representing the command launched (e.g., `status`);
- `status` a string that contains either "OK" or an error string if the command failed;
- `error` an interger value used as a flag to indicate if the command was in error or not, where `0` means success and `1` means error;
- `exit-status` an integer that contains zero if the command run succesfully, another value depending on the specific command in case of failure;
- `output` an object that contains the details of the executed command.

The `output` object is *the variable part* in the JSON command output, that means its effective content depends on the launched command.

Whenever the command output includes an array of stuff, for example a connection list, such array is wrapped into a `list` JSON array with a sibling named `count` that contains the integer size of the array (number of elements).


The following are a few examples of commands that provide output in JSON:


```
pgagroal-cli ping --format json
{
        "command":      {
                "name": "ping",
                "status":       "OK",
                "error":        0,
                "exit-status":  0,
                "output":       {
                        "status":       1,
                        "message":      "running"
                }
        },
        "application":  {
                "name": "pgagroal-cli",
                "major":        1,
                "minor":        6,
                "patch":        0,
                "version":      "1.6.0"
        }
}



pgagroal-cli status --format json
{
        "command":      {
                "name": "status",
                "status":       "OK",
                "error":        0,
                "exit-status":  0,
                "output":       {
                        "status":       {
                                "message":      "Running",
                                "status":       1
                        },
                        "connections":  {
                                "active":       0,
                                "total":        2,
                                "max":  15
                        },
                        "databases":    {
                                "disabled":     {
                                        "count":        0,
                                        "state":        "disabled",
                                        "list": []
                                }
                        }
                }
        },
        "application":  {
                "name": "pgagroal-cli",
                "major":        1,
                "minor":        6,
                "patch":        0,
                "version":      "1.6.0"
        }
}
```

As an example, the following is the output of a faulty `conf set` command (note the `status`, `error` and `exist-status` values):

```
pgagroal-cli conf set max_connections 1000  --format json
{
        "command":      {
                "name": "conf set",
                "status":       "Current and expected values are different",
                "error":        true,
                "exit-status":  2,
                "output":       {
                        "key":  "max_connections",
                        "value":        "15",
                        "expected":     "1000"
                }
        },
        "application":  {
                "name": "pgagroal-cli",
                "major":        1,
                "minor":        6,
                "patch":        0,
                "version":      "1.6.0"
        }
}
```


The `conf ls` command returns an array named `files` where each entry is made by a couple `description` and `path`, where the former
is the mnemonic name of the configuration file, and the latter is the value of the configuration file used:

```
$ pgagroal-cli conf ls --format json
{
        "command":      {
                "name": "conf ls",
                "status":       "OK",
                "error":        0,
                "exit-status":  0,
                "output":       {
                        "files":        {
                                "list": [{
                                                "description":  "Main Configuration file",
                                                "path": "/etc/pgagroal/pgagroal.conf"
                                        }, {
                                                "description":  "HBA File",
                                                "path": "/etc/pgagroal/pgagroal_hba.conf"
                                        }, {
                                                "description":  "Limit file",
                                                "path": "/etc/pgagroal/pgagroal_databases.conf"
                                        }, {
                                                "description":  "Frontend users file",
                                                "path": "/etc/pgagroal/pgagroal_frontend_users.conf"
                                        }, {
                                                "description":  "Admins file",
                                                "path": "/etc/pgagroal/pgagroal_admins.conf"
                                        }, {
                                                "description":  "Superuser file",
                                                "path": ""
                                        }, {
                                                "description":  "Users file",
                                                "path": "/etc/pgagroal/pgagroal_users.conf"
                                        }]
                        }
                }
        },
        "application":  {
                "name": "pgagroal-cli",
                "major":        1,
                "minor":        6,
                "patch":        0,
                "version":      "1.6.0"
        }
}
```
