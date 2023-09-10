package main

import (
    "log"
    "net/http"
)

func main() {
    http.HandleFunc(
        "/",
        func(w http.ResponseWriter, r *http.Request) {
            http.ServeFile(w, r, "zig-out/htmlout/"+r.URL.Path[1:])
        })

    log.Fatal(http.ListenAndServe(":8083", nil))
}
