package main

import (
	"fmt"
	"io"
	"net/http"
	"log"
)

func main() {
	fmt.Println("ehhl")

	handler := func(w http.ResponseWriter, req *http.request) {
		io.WriteString(w, "ehhl\n")
	}

	http.HandleFunc("/hello", handler)
	log.Fatal(http.ListenAndServe(":8888", nil))
}
