package main

import (
	"fmt"
	"math/rand"
	"net/http"
	"time"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Simulate a random latency between 0 and 1s.
		time.Sleep(time.Duration(rand.Intn(1000)) * time.Millisecond)

		// Simulate a random error.
		if rand.Intn(100) < 10 {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprintln(w, "Internal Server Error")
			return
		}

		// Simulate a random 4XX error.
		if rand.Intn(100) < 10 {
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprintln(w, "Not Found")
			return
		}

		fmt.Fprintln(w, "Hello, World!")
	})

	http.ListenAndServe(":80", nil)
}
