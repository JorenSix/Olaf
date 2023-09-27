#!/usr/bin/env python3
# encoding: utf-8
"""Use instead of `python3 -m http.server` when you need CORS"""

#from https://gist.github.com/acdha/925e9ffc3d74ad59c3ea


from http.server import HTTPServer, SimpleHTTPRequestHandler


class CORSRequestHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')

        #Enable CORS for wasm
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')

        #Enable caching for performance reasons
        #self.send_header('Access-Control-Allow-Methods', 'GET')
        #self.send_header('Cache-Control', 'max-age=2592000, stale-while-revalidate=86400e')

        #To disable caching:
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')

        
        return super(CORSRequestHandler, self).end_headers()


httpd = HTTPServer(('localhost', 8003), CORSRequestHandler)

print("Listening on http://localhost:8003\n")

httpd.serve_forever()
