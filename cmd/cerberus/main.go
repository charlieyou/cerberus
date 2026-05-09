package main

import (
	"os"

	"github.com/charlieyou/cerberus/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:]))
}
