#!/usr/bin/env python3
"""Disposable localhost SFTP server used only by integration tests."""

import argparse
import errno
import os
import socket
import threading
from pathlib import Path

import paramiko


class AuthServer(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if (username, password) == ("mock", "mock") else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password"

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


class LocalSFTP(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, root, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.root = Path(root).resolve()

    def _path(self, remote):
        candidate = (self.root / str(remote).lstrip("/")).resolve()
        if candidate != self.root and self.root not in candidate.parents:
            raise OSError(errno.EACCES, "path escapes test root")
        return candidate

    @staticmethod
    def _error(error):
        return paramiko.SFTPServer.convert_errno(error.errno or errno.EIO)

    def canonicalize(self, path):
        try:
            local = self._path(path)
            relative = local.relative_to(self.root)
            return "/" if str(relative) == "." else "/" + str(relative)
        except OSError:
            return "/"

    def list_folder(self, path):
        try:
            result = []
            for child in self._path(path).iterdir():
                attributes = paramiko.SFTPAttributes.from_stat(child.lstat())
                attributes.filename = child.name
                result.append(attributes)
            return result
        except OSError as error:
            return self._error(error)

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self._path(path).stat())
        except OSError as error:
            return self._error(error)

    def lstat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self._path(path).lstat())
        except OSError as error:
            return self._error(error)

    def open(self, path, flags, attr):
        try:
            local = self._path(path)
            local.parent.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(local, flags, 0o666)
            if flags & os.O_RDWR:
                mode = "r+b"
            elif flags & os.O_WRONLY:
                mode = "ab" if flags & os.O_APPEND else "wb"
            else:
                mode = "rb"
            stream = os.fdopen(descriptor, mode, buffering=0)
            handle = paramiko.SFTPHandle(flags)
            handle.readfile = stream
            handle.writefile = stream
            return handle
        except OSError as error:
            return self._error(error)

    def remove(self, path):
        try:
            self._path(path).unlink()
            return paramiko.SFTP_OK
        except OSError as error:
            return self._error(error)

    def rename(self, oldpath, newpath):
        try:
            os.rename(self._path(oldpath), self._path(newpath))
            return paramiko.SFTP_OK
        except OSError as error:
            return self._error(error)

    def mkdir(self, path, attr):
        try:
            self._path(path).mkdir(mode=attr.st_mode or 0o777)
            return paramiko.SFTP_OK
        except OSError as error:
            return self._error(error)

    def rmdir(self, path):
        try:
            self._path(path).rmdir()
            return paramiko.SFTP_OK
        except OSError as error:
            return self._error(error)

    def chattr(self, path, attr):
        try:
            paramiko.SFTPServer.set_file_attr(str(self._path(path)), attr)
            return paramiko.SFTP_OK
        except OSError as error:
            return self._error(error)


def serve_connection(client, host_key, root):
    transport = paramiko.Transport(client)
    transport.add_server_key(host_key)
    transport.set_subsystem_handler("sftp", paramiko.SFTPServer, LocalSFTP, root=root)
    try:
        transport.start_server(server=AuthServer())
        while transport.is_active():
            transport.join(0.2)
    finally:
        transport.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2222)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    Path(args.root).mkdir(parents=True, exist_ok=True)
    (Path(args.root) / "tmp").mkdir(parents=True, exist_ok=True)
    host_key = paramiko.ECDSAKey.generate()
    with socket.create_server((args.host, args.port), reuse_port=False) as listener:
        print(f"READY {args.host}:{args.port}", flush=True)
        while True:
            client, _ = listener.accept()
            threading.Thread(target=serve_connection, args=(client, host_key, args.root), daemon=True).start()


if __name__ == "__main__":
    main()
