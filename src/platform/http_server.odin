package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Orchestrates mimir serve: type-check → deps → shim → spawn.

Serve_Config :: struct {
	script:         string,    // path to .py file
	port:           int,       // default 8080
	host:           string,    // default "127.0.0.1"
	python_version: string,    // "" for default
	skip_deps:      bool,      // --no-deps flag
	static_dir:     string,    // --static <dir> (serve static files)
	tls_cert:       string,    // --tls-cert <path>
	tls_key:        string,    // --tls-key <path>
}

// Main serve orchestration. Returns process exit code.
serve :: proc(config: Serve_Config, allocator: mem.Allocator) -> int {
	// 1. Verify script exists
	if !os.exists(config.script) {
		fmt.eprintfln("mimir serve: script '%s' not found", config.script)
		return 1
	}
	if !os.is_file(config.script) {
		fmt.eprintfln("mimir serve: '%s' is not a file", config.script)
		return 1
	}

	// Verify static dir exists if specified
	if config.static_dir != "" && !os.is_dir(config.static_dir) {
		fmt.eprintfln("mimir serve: static directory '%s' not found", config.static_dir)
		return 1
	}

	// Verify TLS files exist if specified
	if config.tls_cert != "" {
		if !os.is_file(config.tls_cert) {
			fmt.eprintfln("mimir serve: TLS certificate '%s' not found", config.tls_cert)
			return 1
		}
		if config.tls_key == "" {
			fmt.eprintln("mimir serve: --tls-cert requires --tls-key")
			return 1
		}
		if !os.is_file(config.tls_key) {
			fmt.eprintfln("mimir serve: TLS key '%s' not found", config.tls_key)
			return 1
		}
	}

	// 2. Parse PEP 723 metadata
	metadata, meta_err := parse_script_metadata(config.script, allocator)
	if meta_err != nil {
		fmt.eprintfln("mimir serve: %s", error_msg(meta_err))
		return 1
	}

	// 3. Find Python interpreter (managed first, then PATH)
	py_version := config.python_version
	if py_version == "" && metadata.python_version != "" {
		py_version = _extract_version_serve(metadata.python_version)
	}
	python, py_ok := find_managed_python(py_version, allocator)
	if !py_ok {
		python, py_ok = find_python(py_version, allocator)
	}
	if !py_ok {
		if py_version != "" {
			fmt.eprintfln("mimir serve: python%s not found (managed or PATH)", py_version)
		} else {
			fmt.eprintfln("mimir serve: python3 not found (managed or PATH)")
		}
		return 1
	}

	// 4. Resolve dependencies (unless --no-deps)
	package_paths: [dynamic]string
	if !config.skip_deps {
		script_dir := parent_dir(config.script)
		im_paths, im_ok := read_import_map_paths(script_dir, allocator)
		if im_ok {
			package_paths = im_paths
		} else if len(metadata.dependencies) > 0 {
			if !detect_pip(python, allocator) {
				fmt.eprintfln("mimir serve: pip not available for '%s'", python)
				fmt.eprintfln("  install pip: %s -m ensurepip", python)
				return 1
			}
			cache, cache_err := init_cache(allocator)
			if cache_err != nil {
				fmt.eprintfln("mimir serve: %s", error_msg(cache_err))
				return 1
			}
			paths, dep_err := ensure_dependencies(python, metadata.dependencies[:], &cache, allocator)
			if dep_err != nil {
				fmt.eprintfln("mimir serve: %s", error_msg(dep_err))
				return 1
			}
			package_paths = paths
		} else {
			config_path, config_found := find_config(script_dir, allocator)
			if config_found {
				lock_path := lockfile_path(config_path, allocator)
				if os.is_file(lock_path) {
					lf, lf_err := read_lockfile(lock_path, allocator)
					if lf_err != nil {
						fmt.eprintfln("mimir serve: %s", error_msg(lf_err))
						return 1
					}
					cache, cache_err := init_cache(allocator)
					if cache_err != nil {
						fmt.eprintfln("mimir serve: %s", error_msg(cache_err))
						return 1
					}
					package_paths = make([dynamic]string, 0, len(lf.packages), allocator)
					for pkg in lf.packages {
						dir, found := find_package_version(&cache, pkg.name, pkg.version)
						if found {
							append(&package_paths, dir)
						} else {
							if !detect_pip(python, allocator) {
								fmt.eprintfln("mimir serve: pip not available for '%s'", python)
								return 1
							}
							target := package_version_dir(&cache, pkg.name, pkg.version)
							fmt.printfln("  installing %s==%s...", pkg.name, pkg.version)
							inst_err := install_package_pinned(python, pkg.name, pkg.version, target, allocator)
							if inst_err != nil {
								fmt.eprintfln("mimir serve: %s", error_msg(inst_err))
								return 1
							}
							append(&package_paths, target)
						}
					}
				} else {
					proj_config, proj_err := read_config(config_path, allocator)
					if proj_err != nil {
						fmt.eprintfln("mimir serve: %s", error_msg(proj_err))
						return 1
					}
					if len(proj_config.dependencies) > 0 {
						fmt.eprintln("  hint: run 'mimir lock' to create a lockfile for reproducible builds")
						if !detect_pip(python, allocator) {
							fmt.eprintfln("mimir serve: pip not available for '%s'", python)
							return 1
						}
						cache, cache_err := init_cache(allocator)
						if cache_err != nil {
							fmt.eprintfln("mimir serve: %s", error_msg(cache_err))
							return 1
						}
						paths, dep_err := ensure_dependencies(python, proj_config.dependencies[:], &cache, allocator)
						if dep_err != nil {
							fmt.eprintfln("mimir serve: %s", error_msg(dep_err))
							return 1
						}
						package_paths = paths
					}
				}
			}
		}
	}

	// 5. Generate Python runtime shim
	shim_content := generate_serve_shim(config, allocator)

	// 6. Write shim to temp file
	shim_path, shim_ok := write_serve_shim(shim_content, allocator)
	if !shim_ok {
		return 1
	}

	// 7. Build PYTHONPATH (deps + script dir)
	pythonpath := build_pythonpath(package_paths[:], config.script, allocator)
	if pythonpath != "" {
		set_err := os.set_env("PYTHONPATH", pythonpath)
		if set_err != nil {
			fmt.eprintfln("mimir serve: failed to set PYTHONPATH: %v", set_err)
			return 1
		}
	}

	// 8. Spawn Python with shim (blocks until Ctrl+C)
	return spawn_python(python, shim_path, {})
}

// Generate the Python runtime shim that provides mimir.http and runs the user's script.
generate_serve_shim :: proc(config: Serve_Config, allocator: mem.Allocator) -> string {
	buf := make([dynamic]u8, 0, 8192, allocator)

	// ---- Header ----
	_sb(&buf, "#!/usr/bin/env python3\n")
	_sb(&buf, "'''mimir serve runtime - generated by mimir'''\n")
	_sb(&buf, "import sys, os, json, re, importlib.util, struct, hashlib\n")
	_sb(&buf, "from http.server import HTTPServer, BaseHTTPRequestHandler\n")
	_sb(&buf, "from types import ModuleType\n")
	_sb(&buf, "from urllib.parse import urlparse, parse_qs, unquote\n")
	_sb(&buf, "\n")

	// ---- Module injection ----
	_sb(&buf, "# Inject mimir.http into sys.modules\n")
	_sb(&buf, "_mimir = ModuleType('mimir')\n")
	_sb(&buf, "_mimir.__path__ = []\n")
	_sb(&buf, "sys.modules['mimir'] = _mimir\n")
	_sb(&buf, "_http = ModuleType('mimir.http')\n")
	_sb(&buf, "sys.modules['mimir.http'] = _http\n")
	_sb(&buf, "\n")

	// ---- Inject db/crypt/json/data shims so served apps can import them ----
	_sb(&buf, generate_db_shim(allocator))
	_sb(&buf, generate_crypt_shim(allocator))
	_sb(&buf, generate_json_shim(allocator))
	_sb(&buf, generate_data_shim(allocator))
	_sb(&buf, generate_actor_shim(allocator))

	// ---- Route registries ----
	_sb(&buf, "_ROUTES = []\n")
	_sb(&buf, "_WS_ROUTES = []\n")
	_sb(&buf, "\n")

	// ---- Config from Odin ----
	if config.port != 0 {
		_sb(&buf, fmt.tprintf("_PORT_OVERRIDE = %d\n", config.port))
	} else {
		_sb(&buf, "_PORT_OVERRIDE = None\n")
	}
	if config.host != "" {
		_sb(&buf, fmt.tprintf("_HOST_OVERRIDE = '%s'\n", _escape_py_str(config.host)))
	} else {
		_sb(&buf, "_HOST_OVERRIDE = None\n")
	}
	if config.static_dir != "" {
		_sb(&buf, fmt.tprintf("_STATIC_DIR = '%s'\n", _escape_py_str(config.static_dir)))
	} else {
		_sb(&buf, "_STATIC_DIR = None\n")
	}
	if config.tls_cert != "" {
		_sb(&buf, fmt.tprintf("_TLS_CERT = '%s'\n", _escape_py_str(config.tls_cert)))
		_sb(&buf, fmt.tprintf("_TLS_KEY = '%s'\n", _escape_py_str(config.tls_key)))
	} else {
		_sb(&buf, "_TLS_CERT = None\n")
		_sb(&buf, "_TLS_KEY = None\n")
	}
	_sb(&buf, "\n")

	// ---- Request class ----
	_sb(&buf, "class Request:\n")
	_sb(&buf, "    def __init__(self, method='', path='', query_string='',\n")
	_sb(&buf, "                 headers=None, cookies=None, args=None,\n")
	_sb(&buf, "                 form=None, data=b''):\n")
	_sb(&buf, "        self.method = method\n")
	_sb(&buf, "        self.path = path\n")
	_sb(&buf, "        self.query_string = query_string\n")
	_sb(&buf, "        self.headers = headers or {}\n")
	_sb(&buf, "        self.cookies = cookies or {}\n")
	_sb(&buf, "        self.args = args or {}\n")
	_sb(&buf, "        self.form = form or {}\n")
	_sb(&buf, "        self.data = data\n")
	_sb(&buf, "\n")
	_sb(&buf, "    def json(self):\n")
	_sb(&buf, "        return json.loads(self.data)\n")
	_sb(&buf, "\n")
	_sb(&buf, "    def text(self):\n")
	_sb(&buf, "        return self.data.decode('utf-8')\n")
	_sb(&buf, "\n")

	// ---- Response class ----
	_sb(&buf, "class Response:\n")
	_sb(&buf, "    def __init__(self, status_code=200, body=b'', headers=None):\n")
	_sb(&buf, "        self.status_code = status_code\n")
	_sb(&buf, "        self.body = body if isinstance(body, bytes) else body.encode('utf-8')\n")
	_sb(&buf, "        self.headers = headers or {}\n")
	_sb(&buf, "\n")
	_sb(&buf, "    @classmethod\n")
	_sb(&buf, "    def json(cls, data, status=200):\n")
	_sb(&buf, "        body = json.dumps(data).encode('utf-8')\n")
	_sb(&buf, "        return cls(status_code=status, body=body,\n")
	_sb(&buf, "                   headers={'Content-Type': 'application/json'})\n")
	_sb(&buf, "\n")
	_sb(&buf, "    @classmethod\n")
	_sb(&buf, "    def html(cls, content, status=200):\n")
	_sb(&buf, "        body = content.encode('utf-8') if isinstance(content, str) else content\n")
	_sb(&buf, "        return cls(status_code=status, body=body,\n")
	_sb(&buf, "                   headers={'Content-Type': 'text/html; charset=utf-8'})\n")
	_sb(&buf, "\n")
	_sb(&buf, "    @classmethod\n")
	_sb(&buf, "    def text(cls, content, status=200):\n")
	_sb(&buf, "        body = content.encode('utf-8') if isinstance(content, str) else content\n")
	_sb(&buf, "        return cls(status_code=status, body=body,\n")
	_sb(&buf, "                   headers={'Content-Type': 'text/plain; charset=utf-8'})\n")
	_sb(&buf, "\n")
	_sb(&buf, "    @classmethod\n")
	_sb(&buf, "    def redirect(cls, url, status=302):\n")
	_sb(&buf, "        return cls(status_code=status, body=b'',\n")
	_sb(&buf, "                   headers={'Location': url})\n")
	_sb(&buf, "\n")

	// ---- WebSocket class ----
	_sb(&buf, "class WebSocket:\n")
	_sb(&buf, "    '''Minimal WebSocket connection wrapper (RFC 6455).'''\n")
	_sb(&buf, "    GUID = '258EAFA5-E914-47DA-95CA-5AB5DC76E98B'\n")
	_sb(&buf, "\n")
	_sb(&buf, "    def __init__(self, rfile, wfile):\n")
	_sb(&buf, "        self.rfile = rfile\n")
	_sb(&buf, "        self.wfile = wfile\n")
	_sb(&buf, "        self.closed = False\n")
	_sb(&buf, "\n")
	_sb(&buf, "    def receive(self):\n")
	_sb(&buf, "        '''Read one text/binary message. Returns str, bytes, or None on close.'''\n")
	_sb(&buf, "        fragments = bytearray()\n")
	_sb(&buf, "        msg_opcode = None\n")
	_sb(&buf, "        while not self.closed:\n")
	_sb(&buf, "            head = self.rfile.read(2)\n")
	_sb(&buf, "            if len(head) < 2:\n")
	_sb(&buf, "                self.closed = True\n")
	_sb(&buf, "                return None\n")
	_sb(&buf, "            fin = head[0] & 0x80\n")
	_sb(&buf, "            opcode = head[0] & 0x0F\n")
	_sb(&buf, "            masked = head[1] & 0x80\n")
	_sb(&buf, "            length = head[1] & 0x7F\n")
	_sb(&buf, "            if length == 126:\n")
	_sb(&buf, "                length = struct.unpack('>H', self.rfile.read(2))[0]\n")
	_sb(&buf, "            elif length == 127:\n")
	_sb(&buf, "                length = struct.unpack('>Q', self.rfile.read(8))[0]\n")
	_sb(&buf, "            if masked:\n")
	_sb(&buf, "                mask = self.rfile.read(4)\n")
	_sb(&buf, "                raw = bytearray(self.rfile.read(length))\n")
	_sb(&buf, "                for i in range(length):\n")
	_sb(&buf, "                    raw[i] ^= mask[i % 4]\n")
	_sb(&buf, "                payload = bytes(raw)\n")
	_sb(&buf, "            else:\n")
	_sb(&buf, "                payload = self.rfile.read(length)\n")
	_sb(&buf, "            if opcode == 0x8:  # close\n")
	_sb(&buf, "                self._send_frame(0x8, b'')\n")
	_sb(&buf, "                self.closed = True\n")
	_sb(&buf, "                return None\n")
	_sb(&buf, "            if opcode == 0x9:  # ping\n")
	_sb(&buf, "                self._send_frame(0xA, payload)  # pong\n")
	_sb(&buf, "                continue\n")
	_sb(&buf, "            if opcode == 0xA:  # pong\n")
	_sb(&buf, "                continue\n")
	_sb(&buf, "            if opcode == 0x0:  # continuation\n")
	_sb(&buf, "                fragments.extend(payload)\n")
	_sb(&buf, "            else:\n")
	_sb(&buf, "                msg_opcode = opcode\n")
	_sb(&buf, "                fragments.extend(payload)\n")
	_sb(&buf, "            if fin:\n")
	_sb(&buf, "                data = bytes(fragments)\n")
	_sb(&buf, "                fragments = bytearray()\n")
	_sb(&buf, "                if msg_opcode == 0x1:\n")
	_sb(&buf, "                    return data.decode('utf-8')\n")
	_sb(&buf, "                return data\n")
	_sb(&buf, "        return None\n")
	_sb(&buf, "\n")
	_sb(&buf, "    def send(self, data):\n")
	_sb(&buf, "        '''Send a text or binary message.'''\n")
	_sb(&buf, "        if isinstance(data, str):\n")
	_sb(&buf, "            self._send_frame(0x1, data.encode('utf-8'))\n")
	_sb(&buf, "        else:\n")
	_sb(&buf, "            self._send_frame(0x2, data)\n")
	_sb(&buf, "\n")
	_sb(&buf, "    def close(self):\n")
	_sb(&buf, "        '''Send close frame.'''\n")
	_sb(&buf, "        if not self.closed:\n")
	_sb(&buf, "            self._send_frame(0x8, b'')\n")
	_sb(&buf, "            self.closed = True\n")
	_sb(&buf, "\n")
	_sb(&buf, "    def _send_frame(self, opcode, payload):\n")
	_sb(&buf, "        '''Send an unmasked WebSocket frame (server to client).'''\n")
	_sb(&buf, "        frame = bytearray()\n")
	_sb(&buf, "        frame.append(0x80 | opcode)  # FIN + opcode\n")
	_sb(&buf, "        length = len(payload)\n")
	_sb(&buf, "        if length < 126:\n")
	_sb(&buf, "            frame.append(length)\n")
	_sb(&buf, "        elif length < 65536:\n")
	_sb(&buf, "            frame.append(126)\n")
	_sb(&buf, "            frame.extend(struct.pack('>H', length))\n")
	_sb(&buf, "        else:\n")
	_sb(&buf, "            frame.append(127)\n")
	_sb(&buf, "            frame.extend(struct.pack('>Q', length))\n")
	_sb(&buf, "        frame.extend(payload)\n")
	_sb(&buf, "        self.wfile.write(bytes(frame))\n")
	_sb(&buf, "        self.wfile.flush()\n")
	_sb(&buf, "\n")

	// ---- route() decorator ----
	_sb(&buf, "def route(method, path):\n")
	_sb(&buf, "    def decorator(func):\n")
	_sb(&buf, "        pat = re.sub(\n")
	_sb(&buf, "            r'\\{(\\w+)\\}|<(?:\\w+:)?(\\w+)>',\n")
	_sb(&buf, "            lambda m: '(?P<' + (m.group(1) or m.group(2)) + '>[^/]+)',\n")
	_sb(&buf, "            path)\n")
	_sb(&buf, "        _ROUTES.append((method.upper(), re.compile('^' + pat + '$'), func))\n")
	_sb(&buf, "        return func\n")
	_sb(&buf, "    return decorator\n")
	_sb(&buf, "\n")

	// ---- websocket() decorator ----
	_sb(&buf, "def websocket(func):\n")
	_sb(&buf, "    '''Register a WebSocket handler. Endpoint path = /<function_name>.'''\n")
	_sb(&buf, "    ws_path = '/' + func.__name__\n")
	_sb(&buf, "    _WS_ROUTES.append((re.compile('^' + re.escape(ws_path) + '$'), func))\n")
	_sb(&buf, "    return func\n")
	_sb(&buf, "\n")

	// ---- serve() function ----
	_sb(&buf, "def serve(port=8080, host='127.0.0.1'):\n")
	_sb(&buf, "    if _PORT_OVERRIDE is not None: port = _PORT_OVERRIDE\n")
	_sb(&buf, "    if _HOST_OVERRIDE is not None: host = _HOST_OVERRIDE\n")
	_sb(&buf, "    server = HTTPServer((host, port), _Handler)\n")
	_sb(&buf, "    if _TLS_CERT and _TLS_KEY:\n")
	_sb(&buf, "        import ssl\n")
	_sb(&buf, "        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)\n")
	_sb(&buf, "        ctx.load_cert_chain(_TLS_CERT, _TLS_KEY)\n")
	_sb(&buf, "        server.socket = ctx.wrap_socket(server.socket, server_side=True)\n")
	_sb(&buf, "        scheme = 'https'\n")
	_sb(&buf, "    else:\n")
	_sb(&buf, "        scheme = 'http'\n")
	_sb(&buf, "    print(f'  mimir serve: {scheme}://{host}:{port}')\n")
	_sb(&buf, "    if _STATIC_DIR:\n")
	_sb(&buf, "        print(f'  mimir serve: static files from {_STATIC_DIR}')\n")
	_sb(&buf, "    if _WS_ROUTES:\n")
	_sb(&buf, "        paths = ', '.join(p.pattern.strip('^$') for p, _ in _WS_ROUTES)\n")
	_sb(&buf, "        print(f'  mimir serve: websocket endpoints: {paths}')\n")
	_sb(&buf, "    print(f'  mimir serve: press Ctrl+C to stop')\n")
	_sb(&buf, "    try:\n")
	_sb(&buf, "        server.serve_forever()\n")
	_sb(&buf, "    except KeyboardInterrupt:\n")
	_sb(&buf, "        print('\\n  mimir serve: shutting down')\n")
	_sb(&buf, "        server.shutdown()\n")
	_sb(&buf, "\n")

	// ---- HTTP client functions (urllib wrappers) ----
	_sb(&buf, "def _http_request(method, url, headers=None, data=None, timeout=30.0):\n")
	_sb(&buf, "    import urllib.request\n")
	_sb(&buf, "    req = urllib.request.Request(url, method=method,\n")
	_sb(&buf, "                                 headers=headers or {}, data=data)\n")
	_sb(&buf, "    try:\n")
	_sb(&buf, "        resp = urllib.request.urlopen(req, timeout=timeout)\n")
	_sb(&buf, "        return Response(status_code=resp.status, body=resp.read(),\n")
	_sb(&buf, "                        headers=dict(resp.headers))\n")
	_sb(&buf, "    except urllib.request.HTTPError as e:\n")
	_sb(&buf, "        return Response(status_code=e.code, body=e.read(),\n")
	_sb(&buf, "                        headers=dict(e.headers))\n")
	_sb(&buf, "    except urllib.request.URLError as e:\n")
	_sb(&buf, "        raise ConnectionError(f'Request failed: {e.reason}') from e\n")
	_sb(&buf, "\n")
	_sb(&buf, "def get(url, headers=None, timeout=30.0):\n")
	_sb(&buf, "    return _http_request('GET', url, headers=headers, timeout=timeout)\n")
	_sb(&buf, "\n")
	_sb(&buf, "def post(url, json_data=None, data=None, headers=None, timeout=30.0):\n")
	_sb(&buf, "    hdrs = dict(headers or {})\n")
	_sb(&buf, "    body = data\n")
	_sb(&buf, "    if json_data is not None:\n")
	_sb(&buf, "        body = json.dumps(json_data).encode('utf-8')\n")
	_sb(&buf, "        hdrs.setdefault('Content-Type', 'application/json')\n")
	_sb(&buf, "    return _http_request('POST', url, headers=hdrs, data=body, timeout=timeout)\n")
	_sb(&buf, "\n")
	_sb(&buf, "def put(url, json_data=None, data=None, headers=None, timeout=30.0):\n")
	_sb(&buf, "    hdrs = dict(headers or {})\n")
	_sb(&buf, "    body = data\n")
	_sb(&buf, "    if json_data is not None:\n")
	_sb(&buf, "        body = json.dumps(json_data).encode('utf-8')\n")
	_sb(&buf, "        hdrs.setdefault('Content-Type', 'application/json')\n")
	_sb(&buf, "    return _http_request('PUT', url, headers=hdrs, data=body, timeout=timeout)\n")
	_sb(&buf, "\n")
	_sb(&buf, "def delete(url, headers=None, timeout=30.0):\n")
	_sb(&buf, "    return _http_request('DELETE', url, headers=headers, timeout=timeout)\n")
	_sb(&buf, "\n")
	_sb(&buf, "def patch(url, json_data=None, data=None, headers=None, timeout=30.0):\n")
	_sb(&buf, "    hdrs = dict(headers or {})\n")
	_sb(&buf, "    body = data\n")
	_sb(&buf, "    if json_data is not None:\n")
	_sb(&buf, "        body = json.dumps(json_data).encode('utf-8')\n")
	_sb(&buf, "        hdrs.setdefault('Content-Type', 'application/json')\n")
	_sb(&buf, "    return _http_request('PATCH', url, headers=hdrs, data=body, timeout=timeout)\n")
	_sb(&buf, "\n")

	// ---- HTTP handler ----
	_sb(&buf, "class _Handler(BaseHTTPRequestHandler):\n")
	_sb(&buf, "    def do_GET(self): self._dispatch('GET')\n")
	_sb(&buf, "    def do_POST(self): self._dispatch('POST')\n")
	_sb(&buf, "    def do_PUT(self): self._dispatch('PUT')\n")
	_sb(&buf, "    def do_DELETE(self): self._dispatch('DELETE')\n")
	_sb(&buf, "    def do_PATCH(self): self._dispatch('PATCH')\n")
	_sb(&buf, "    def do_HEAD(self): self._dispatch('HEAD')\n")
	_sb(&buf, "    def do_OPTIONS(self): self._dispatch('OPTIONS')\n")
	_sb(&buf, "\n")

	// ---- WebSocket upgrade detection ----
	_sb(&buf, "    def _check_websocket_upgrade(self, path):\n")
	_sb(&buf, "        '''Handle WebSocket upgrade if applicable. Returns True if handled.'''\n")
	_sb(&buf, "        upgrade = self.headers.get('Upgrade', '').lower()\n")
	_sb(&buf, "        if upgrade != 'websocket':\n")
	_sb(&buf, "            return False\n")
	_sb(&buf, "        for pattern, handler in _WS_ROUTES:\n")
	_sb(&buf, "            if pattern.match(path):\n")
	_sb(&buf, "                key = self.headers.get('Sec-WebSocket-Key', '')\n")
	_sb(&buf, "                if not key:\n")
	_sb(&buf, "                    self.send_error(400, 'Missing Sec-WebSocket-Key')\n")
	_sb(&buf, "                    return True\n")
	_sb(&buf, "                accept = hashlib.sha1(\n")
	_sb(&buf, "                    (key + WebSocket.GUID).encode()\n")
	_sb(&buf, "                ).digest()\n")
	_sb(&buf, "                import base64\n")
	_sb(&buf, "                accept_b64 = base64.b64encode(accept).decode()\n")
	_sb(&buf, "                self.send_response(101)\n")
	_sb(&buf, "                self.send_header('Upgrade', 'websocket')\n")
	_sb(&buf, "                self.send_header('Connection', 'Upgrade')\n")
	_sb(&buf, "                self.send_header('Sec-WebSocket-Accept', accept_b64)\n")
	_sb(&buf, "                self.end_headers()\n")
	_sb(&buf, "                ws = WebSocket(self.rfile, self.wfile)\n")
	_sb(&buf, "                try:\n")
	_sb(&buf, "                    handler(ws)\n")
	_sb(&buf, "                except Exception:\n")
	_sb(&buf, "                    import traceback\n")
	_sb(&buf, "                    traceback.print_exc()\n")
	_sb(&buf, "                finally:\n")
	_sb(&buf, "                    ws.close()\n")
	_sb(&buf, "                return True\n")
	_sb(&buf, "        return False\n")
	_sb(&buf, "\n")

	// ---- Static file serving ----
	_sb(&buf, "    def _serve_static(self, path):\n")
	_sb(&buf, "        '''Try to serve a static file. Returns True if served.'''\n")
	_sb(&buf, "        if not _STATIC_DIR:\n")
	_sb(&buf, "            return False\n")
	_sb(&buf, "        import mimetypes\n")
	_sb(&buf, "        # Prevent directory traversal\n")
	_sb(&buf, "        clean = os.path.normpath(path.lstrip('/'))\n")
	_sb(&buf, "        if clean.startswith('..'):\n")
	_sb(&buf, "            return False\n")
	_sb(&buf, "        file_path = os.path.join(_STATIC_DIR, clean)\n")
	_sb(&buf, "        if os.path.isdir(file_path):\n")
	_sb(&buf, "            file_path = os.path.join(file_path, 'index.html')\n")
	_sb(&buf, "        if not os.path.isfile(file_path):\n")
	_sb(&buf, "            return False\n")
	_sb(&buf, "        mime_type, _ = mimetypes.guess_type(file_path)\n")
	_sb(&buf, "        try:\n")
	_sb(&buf, "            with open(file_path, 'rb') as f:\n")
	_sb(&buf, "                data = f.read()\n")
	_sb(&buf, "        except OSError:\n")
	_sb(&buf, "            return False\n")
	_sb(&buf, "        self.send_response(200)\n")
	_sb(&buf, "        self.send_header('Content-Type', mime_type or 'application/octet-stream')\n")
	_sb(&buf, "        self.send_header('Content-Length', str(len(data)))\n")
	_sb(&buf, "        self.end_headers()\n")
	_sb(&buf, "        self.wfile.write(data)\n")
	_sb(&buf, "        return True\n")
	_sb(&buf, "\n")

	// ---- Main dispatch ----
	_sb(&buf, "    def _dispatch(self, method):\n")
	_sb(&buf, "        parsed = urlparse(self.path)\n")
	_sb(&buf, "        path = unquote(parsed.path)\n")
	_sb(&buf, "        qs = parsed.query\n")
	_sb(&buf, "\n")
	_sb(&buf, "        # WebSocket upgrade check\n")
	_sb(&buf, "        if method == 'GET' and self._check_websocket_upgrade(path):\n")
	_sb(&buf, "            return\n")
	_sb(&buf, "\n")
	_sb(&buf, "        # Route matching\n")
	_sb(&buf, "        for route_method, pattern, handler in _ROUTES:\n")
	_sb(&buf, "            if method != route_method:\n")
	_sb(&buf, "                continue\n")
	_sb(&buf, "            m = pattern.match(path)\n")
	_sb(&buf, "            if m is None:\n")
	_sb(&buf, "                continue\n")
	_sb(&buf, "\n")
	_sb(&buf, "            content_len = int(self.headers.get('Content-Length', 0))\n")
	_sb(&buf, "            if content_len > 10_485_760:  # 10 MB limit\n")
	_sb(&buf, "                self.send_response(413)\n")
	_sb(&buf, "                self.send_header('Content-Type', 'text/plain')\n")
	_sb(&buf, "                self.end_headers()\n")
	_sb(&buf, "                self.wfile.write(b'Request body too large')\n")
	_sb(&buf, "                return\n")
	_sb(&buf, "            body = self.rfile.read(content_len) if content_len > 0 else b''\n")
	_sb(&buf, "\n")
	_sb(&buf, "            args = {}\n")
	_sb(&buf, "            if qs:\n")
	_sb(&buf, "                for k, v in parse_qs(qs).items():\n")
	_sb(&buf, "                    args[k] = v[0] if len(v) == 1 else v[-1]\n")
	_sb(&buf, "\n")
	_sb(&buf, "            cookies = {}\n")
	_sb(&buf, "            cookie_header = self.headers.get('Cookie', '')\n")
	_sb(&buf, "            if cookie_header:\n")
	_sb(&buf, "                for part in cookie_header.split(';'):\n")
	_sb(&buf, "                    part = part.strip()\n")
	_sb(&buf, "                    if '=' in part:\n")
	_sb(&buf, "                        k, v = part.split('=', 1)\n")
	_sb(&buf, "                        cookies[k.strip()] = v.strip()\n")
	_sb(&buf, "\n")
	_sb(&buf, "            form = {}\n")
	_sb(&buf, "            ct = self.headers.get('Content-Type', '')\n")
	_sb(&buf, "            if 'application/x-www-form-urlencoded' in ct and body:\n")
	_sb(&buf, "                for k, v in parse_qs(body.decode('utf-8')).items():\n")
	_sb(&buf, "                    form[k] = v[0] if len(v) == 1 else v[-1]\n")
	_sb(&buf, "\n")
	_sb(&buf, "            hdrs = {}\n")
	_sb(&buf, "            for k in self.headers:\n")
	_sb(&buf, "                hdrs[k] = self.headers[k]\n")
	_sb(&buf, "\n")
	_sb(&buf, "            request = Request(\n")
	_sb(&buf, "                method=method, path=path, query_string=qs,\n")
	_sb(&buf, "                headers=hdrs, cookies=cookies, args=args,\n")
	_sb(&buf, "                form=form, data=body,\n")
	_sb(&buf, "            )\n")
	_sb(&buf, "\n")
	_sb(&buf, "            try:\n")
	_sb(&buf, "                response = handler(request, **m.groupdict())\n")
	_sb(&buf, "            except Exception:\n")
	_sb(&buf, "                import traceback\n")
	_sb(&buf, "                traceback.print_exc()\n")
	_sb(&buf, "                self.send_response(500)\n")
	_sb(&buf, "                self.send_header('Content-Type', 'text/plain')\n")
	_sb(&buf, "                self.end_headers()\n")
	_sb(&buf, "                self.wfile.write(b'Internal Server Error')\n")
	_sb(&buf, "                return\n")
	_sb(&buf, "\n")
	_sb(&buf, "            self.send_response(response.status_code)\n")
	_sb(&buf, "            for k, v in response.headers.items():\n")
	_sb(&buf, "                self.send_header(k, v)\n")
	_sb(&buf, "            if 'Content-Length' not in response.headers:\n")
	_sb(&buf, "                self.send_header('Content-Length', str(len(response.body)))\n")
	_sb(&buf, "            self.end_headers()\n")
	_sb(&buf, "            self.wfile.write(response.body)\n")
	_sb(&buf, "            return\n")
	_sb(&buf, "\n")
	_sb(&buf, "        # Static file fallback (GET only)\n")
	_sb(&buf, "        if method == 'GET' and self._serve_static(path):\n")
	_sb(&buf, "            return\n")
	_sb(&buf, "\n")
	_sb(&buf, "        # No route matched\n")
	_sb(&buf, "        self.send_response(404)\n")
	_sb(&buf, "        self.send_header('Content-Type', 'application/json')\n")
	_sb(&buf, "        self.end_headers()\n")
	_sb(&buf, "        self.wfile.write(json.dumps({'error': 'Not Found', 'path': path}).encode())\n")
	_sb(&buf, "\n")
	_sb(&buf, "    def log_message(self, fmt_str, *args):\n")
	_sb(&buf, "        if len(args) >= 3:\n")
	_sb(&buf, "            sys.stderr.write(f'  {args[0]} {args[1]} {args[2]}\\n')\n")
	_sb(&buf, "        else:\n")
	_sb(&buf, "            sys.stderr.write(f'  {fmt_str % args}\\n')\n")
	_sb(&buf, "\n")

	// ---- Export to mimir.http module ----
	_sb(&buf, "# Wire up module exports\n")
	_sb(&buf, "_http.Request = Request\n")
	_sb(&buf, "_http.Response = Response\n")
	_sb(&buf, "_http.WebSocket = WebSocket\n")
	_sb(&buf, "_http.route = route\n")
	_sb(&buf, "_http.serve = serve\n")
	_sb(&buf, "_http.websocket = websocket\n")
	_sb(&buf, "_http.get = get\n")
	_sb(&buf, "_http.post = post\n")
	_sb(&buf, "_http.put = put\n")
	_sb(&buf, "_http.delete = delete\n")
	_sb(&buf, "_http.patch = patch\n")
	_sb(&buf, "\n")

	// ---- Run user script ----
	_sb(&buf, "# Run user script as __main__\n")
	_sb(&buf, fmt.tprintf("_script_dir = '%s'\n", _escape_py_str(parent_dir(config.script))))
	_sb(&buf, "if _script_dir not in sys.path:\n")
	_sb(&buf, "    sys.path.insert(0, _script_dir)\n")
	_sb(&buf, "\n")
	_sb(&buf, fmt.tprintf("_script_path = '%s'\n", _escape_py_str(config.script)))
	_sb(&buf, "spec = importlib.util.spec_from_file_location('__main__', _script_path)\n")
	_sb(&buf, "if spec is None or spec.loader is None:\n")
	_sb(&buf, "    print(f'mimir serve: failed to load {_script_path}', file=sys.stderr)\n")
	_sb(&buf, "    sys.exit(1)\n")
	_sb(&buf, "mod = importlib.util.module_from_spec(spec)\n")
	_sb(&buf, "sys.modules['__main__'] = mod\n")
	_sb(&buf, "spec.loader.exec_module(mod)\n")

	return string(buf[:])
}

// Write shim content to a temp file. Returns path and success.
write_serve_shim :: proc(content: string, allocator: mem.Allocator) -> (path: string, ok: bool) {
	tmp_dir, tmp_err := os.temp_directory(allocator)
	if tmp_err != nil {
		tmp_dir = "/tmp"
	}

	pid := os.get_pid()
	shim_path := fmt.aprintf("%s/_mimir_serve_%d.py", tmp_dir, pid, allocator = allocator)

	write_err := os.write_entire_file(shim_path, transmute([]u8)content)
	if write_err != nil {
		fmt.eprintfln("mimir serve: failed to write shim to %s: %v", shim_path, write_err)
		return "", false
	}

	return shim_path, true
}

// Append string to byte buffer.
@(private = "file")
_sb :: proc(buf: ^[dynamic]u8, s: string) {
	for i in 0..<len(s) { append(buf, s[i]) }
}

// Escape a string for embedding in Python single-quoted string literals.
@(private = "file")
_escape_py_str :: proc(s: string) -> string {
	needs_escape := false
	for i in 0..<len(s) {
		c := s[i]
		if c == '\'' || c == '\\' || c == '\n' || c == '\r' || c == 0 {
			needs_escape = true
			break
		}
	}
	if !needs_escape { return s }

	result := make([dynamic]u8, 0, len(s) + 8, context.temp_allocator)
	for i in 0..<len(s) {
		c := s[i]
		switch c {
		case '\'':  append(&result, '\\'); append(&result, '\'')
		case '\\':  append(&result, '\\'); append(&result, '\\')
		case '\n':  append(&result, '\\'); append(&result, 'n')
		case '\r':  append(&result, '\\'); append(&result, 'r')
		case 0:     append(&result, '\\'); append(&result, '0')
		case:       append(&result, c)
		}
	}
	return string(result[:])
}

// Extract version number from constraint (e.g. ">=3.12" → "3.12").
@(private = "file")
_extract_version_serve :: proc(constraint: string) -> string {
	s := constraint
	for s != "" && (s[0] == '>' || s[0] == '<' || s[0] == '=' || s[0] == '~' || s[0] == '!') {
		s = s[1:]
	}
	return strings.trim_space(s)
}
