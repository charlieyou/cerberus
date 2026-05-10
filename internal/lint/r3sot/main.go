package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func main() {
	if err := run("."); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("R3 single-source-of-truth lint: ok")
}

func run(root string) error {
	var failures []string
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			return nil
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", ".beads":
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Ext(path) != ".go" {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			return nil
		}
		rel = filepath.ToSlash(rel)
		if allowedR3Owner(rel) || strings.HasSuffix(rel, "_test.go") {
			return nil
		}
		failures = append(failures, lintGoFile(rel, path)...)
		return nil
	})
	if err != nil {
		return err
	}
	if len(failures) > 0 {
		return fmt.Errorf("R3 single-source-of-truth lint failed:\n%s", strings.Join(failures, "\n"))
	}
	return nil
}

func lintGoFile(rel, path string) []string {
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ParseComments)
	if err != nil {
		return []string{fmt.Sprintf("%s: %v", rel, err)}
	}
	var failures []string
	for _, decl := range file.Decls {
		switch typed := decl.(type) {
		case *ast.FuncDecl:
			if forbiddenOwnedSymbol(typed.Name.Name) {
				failures = append(failures, fmt.Sprintf("%s: top-level symbol %s duplicates aggregate/anonymize ownership", rel, typed.Name.Name))
			}
		case *ast.GenDecl:
			for _, spec := range typed.Specs {
				for _, name := range specNames(spec) {
					if forbiddenOwnedSymbol(name) {
						failures = append(failures, fmt.Sprintf("%s: top-level symbol %s duplicates aggregate/anonymize ownership", rel, name))
					}
				}
			}
		}
	}
	ast.Inspect(file, func(node ast.Node) bool {
		expr, ok := node.(ast.Expr)
		if !ok {
			return true
		}
		value, ok := stringExprValue(expr)
		if !ok {
			return true
		}
		if strings.Contains(value, gateStateName()) {
			failures = append(failures, fmt.Sprintf("%s: direct %s literal outside internal/state bypasses state I/O ownership", rel, gateStateName()))
			return false
		}
		return true
	})
	return failures
}

func stringExprValue(expr ast.Expr) (string, bool) {
	switch typed := expr.(type) {
	case *ast.BasicLit:
		if typed.Kind != token.STRING {
			return "", false
		}
		value, err := strconv.Unquote(typed.Value)
		return value, err == nil
	case *ast.BinaryExpr:
		if typed.Op != token.ADD {
			return "", false
		}
		left, ok := stringExprValue(typed.X)
		if !ok {
			return "", false
		}
		right, ok := stringExprValue(typed.Y)
		if !ok {
			return "", false
		}
		return left + right, true
	default:
		return "", false
	}
}

func gateStateName() string {
	return strings.Join([]string{"gate-state", ".json"}, "")
}

func allowedR3Owner(rel string) bool {
	for _, prefix := range []string{"internal/aggregate/", "internal/anonymize/", "internal/state/"} {
		if strings.HasPrefix(rel, prefix) {
			return true
		}
	}
	return false
}

func forbiddenOwnedSymbol(name string) bool {
	return strings.HasPrefix(name, "Aggregate") || strings.HasPrefix(name, "Anonymize")
}

func specNames(spec ast.Spec) []string {
	switch typed := spec.(type) {
	case *ast.TypeSpec:
		return []string{typed.Name.Name}
	case *ast.ValueSpec:
		names := make([]string, 0, len(typed.Names))
		for _, name := range typed.Names {
			names = append(names, name.Name)
		}
		return names
	default:
		return nil
	}
}
