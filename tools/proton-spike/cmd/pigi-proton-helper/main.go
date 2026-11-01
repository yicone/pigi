package main

import (
	"io"
	"log"
	"os"
	"pigi-proton-spike/internal/helper"
)

func main() {
	log.SetOutput(io.Discard)
	// Panic stacks can contain arguments or upstream data. Fail closed silently.
	defer func() {
		if recover() != nil {
			os.Exit(1)
		}
	}()
	if len(os.Args) != 1 {
		os.Exit(2)
	}
	if helper.Serve(os.Stdin, os.Stdout, helper.NewBackend()) != nil {
		os.Exit(1)
	}
}
