package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"

	client "github.com/samcat116/strato/internal/client"
)

func main() {

	setupCHVClient()
	//httpClient := &http.Client{
	//	Transport: &http.Transport{
	//		DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
	//			return net.Dial("unix", "/path/to/cloud-hypervisor.sock")
	//		},
	//	},
	//}

	client, error := client.NewClientWithResponses("http://samstack:8080/api/v1")

	if error != nil {
		log.Fatalf("Failed to create client: %v", error)
	}

	ctx := context.Background()
	response, error := client.GetVmmPingWithResponse(ctx)
	if error != nil {
		log.Fatalf("Failed to get VMs: %v", error)
	}
	fmt.Println(response.JSON200.Version)

	handler := func(w http.ResponseWriter, req *http.Request) {
		io.WriteString(w, "Hello!")
	}

	http.HandleFunc("/hello", handler)
	log.Fatal(http.ListenAndServe(":8888", nil))
}

func setupCHVClient() {
	// check if the api is listening on a unix socket

}
