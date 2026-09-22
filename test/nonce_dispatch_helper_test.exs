defmodule R5eRecurse.NonceDispatchHelperTest do
  use ExUnit.Case, async: true
  @moduletag timeout: 10_000

  test "ownership remains held until dispatch process dies, and death before POST sends no bytes" do
    helper = Application.app_dir(:r5e_recurse, "priv/nonce_journal/journal_io.py")

    script = ~S"""
    import json, os, socket, subprocess, sys, tempfile
    helper = sys.argv[1]
    wrapper = '''import http.client, runpy, sys
    connect = http.client.HTTPConnection.connect
    def paused(self):
        connect(self)
        print("connected-before-post", flush=True)
        sys.stdin.buffer.read(1)
    http.client.HTTPConnection.connect = paused
    runpy.run_path(sys.argv[1], run_name="__main__")
    '''
    # run_path sees the helper pathname as argv[1]; adapt argv before entry.
    wrapper = wrapper.replace('runpy.run_path(sys.argv[1], run_name="__main__")', 'path = sys.argv.pop(1)\nrunpy.run_path(path, run_name="__main__")')
    with tempfile.TemporaryDirectory() as parent:
        directory = os.path.join(parent, "journal")
        os.mkdir(directory, 0o700)
        name = "sha256:" + "a" * 64 + ".json"
        with open(os.path.join(directory, name), "w") as out:
            json.dump({"candidate": {"target": {"group": "test", "version": "v1", "kind": "Test", "name": None}, "spec": {}}, "envelope": {}}, out)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(2)
            owner = subprocess.Popen([sys.executable, "-c", wrapper, helper, directory], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            try:
                assert owner.stdout.readline() == b"acquired\n"
                command = json.dumps({"action": "dispatch", "name": name, "url": "http://127.0.0.1:" + str(listener.getsockname()[1]), "timeout": 2000}).encode()
                owner.stdin.write(len(command).to_bytes(4, "big") + command)
                owner.stdin.flush()
                connection, _ = listener.accept()
                connection.settimeout(2)
                with connection:
                    assert owner.stdout.readline() == b"connected-before-post\n"
                    contender = subprocess.run([sys.executable, helper, directory], input=b"", capture_output=True, timeout=2)
                    assert contender.returncode == 3 and contender.stdout == b"busy\n"
                    owner.kill()
                    owner.wait(timeout=2)
                    successor = subprocess.run([sys.executable, helper, directory], input=b"", capture_output=True, timeout=2)
                    assert successor.returncode == 0 and successor.stdout == b"acquired\n"
                    assert connection.recv(4096) == b"", "former owner dispatched after losing lock"
            finally:
                if owner.poll() is None:
                    owner.kill()
                owner.wait(timeout=2)
    print("dispatch-fence-verified")
    """

    assert {"dispatch-fence-verified\n", 0} = System.cmd("python3", ["-c", script, helper])
  end
end
