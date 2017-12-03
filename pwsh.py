#!/usr/bin/env python3
'''..module: pwsh

execute powershell commands remotely
'''

import base64
import sys
import argparse

import requests.exceptions

from winrm.protocol import Protocol

def _type_password(string):
    ftype, field = string.split(':', 1)
    if ftype == 'pass':
        return field
    if ftype == 'file':
        with open(field) as fin:
            return fin.read().strip()
    raise ValueError(string)

PARSER = argparse.ArgumentParser(
    description='Execute powershell commands on a remote host',
    add_help=False)

PARSER.add_argument('-h', '--host', required=True)
PARSER.add_argument('-u', '--user', required=True)
PARSER.add_argument('-p', '--password', required=True, type=_type_password)
PARSER.add_argument('-c', '--shell', action='store_true', help='execute first argument directly')
PARSER.add_argument('--port', type=int, default=5986)
PARSER.add_argument('--endpoint', default='wsman')
PARSER.add_argument('--use-http', action='store_true')
PARSER.add_argument('--help', action='help')
PARSER.add_argument('command', nargs='+')

def parse_args(argv=None):
    return PARSER.parse_args(argv)


def main():
    args = parse_args()
    endpoint = '{}://{}:{}/{}'.format(
        'http' if args.use_http else 'https',
        args.host,
        args.port,
        args.endpoint
    )
    username = args.user
    if '\\' not in username or '@' not in username:
        username = '{}\\{}'.format(args.host.split('.')[0], username)

    if args.shell:
        command = args.command[0]
        arguments = args.command[1:]
    else:
        command = 'powershell'
        encoded_command = ' '.join(args.command)
        encoded_command = base64.b64encode(encoded_command.encode('utf-16-le'))
        arguments = ['-EncodedCommand', encoded_command]

    proto = Protocol(endpoint, 'ntlm', username, args.password, server_cert_validation='ignore')
    shell_id = proto.open_shell()
    command_id = proto.run_command(shell_id, command, arguments)
    std_out, std_err, status_code = proto.get_command_output(shell_id, command_id)
    sys.stdout.write(std_out.decode('utf-8'))
    # sys.stderr.write(std_err.decode('utf-8'))
    proto.cleanup_command(shell_id, command_id)
    proto.close_shell(shell_id)
    return status_code

if __name__ == '__main__':
    try:
        sys.exit(main())
    except requests.exceptions.RequestException as exp:
        print('Error: {}'.format(exp))
        sys.exit(2)
