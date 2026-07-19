// Command vaultsecret is a generic replacement for the repository's
// per-integration scripts/configure-*.sh scripts. Every one of those scripts
// repeats the same sequence: wait for Vault, prompt for the root token,
// write a read-only policy, write a Kubernetes auth role bound to one
// ServiceAccount, write the secret fields into Vault KV v2, then wait for
// External Secrets to sync the Kubernetes Secret. This tool performs that
// same sequence for an arbitrary secret path, driven entirely by flags, so
// adding a new integration never requires a new shell script.
//
// Vault itself is never exposed outside the cluster network; all Vault CLI
// calls run inside the Vault Pod via `kubectl exec`, matching the existing
// scripts. Secret values are always sent over the exec stdin pipe, never as
// command-line arguments or environment variables passed to a child
// process, and are never printed.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
)

const vaultAddr = "http://127.0.0.1:8200"

var (
	reFieldKey    = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*$`)
	reSimpleName  = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	rePath        = regexp.MustCompile(`^[A-Za-z0-9_.\-]+(/[A-Za-z0-9_.\-]+)*$`)
	reTTL         = regexp.MustCompile(`^[0-9]+(ms|s|m|h)$`)
	allowedCapSet = map[string]bool{
		"create": true, "read": true, "update": true, "patch": true,
		"delete": true, "list": true, "sudo": true, "deny": true,
	}
)

type fieldKind int

const (
	fieldLiteral fieldKind = iota
	fieldPrompt
	fieldFile
	fieldEnv
)

type fieldSpec struct {
	kind fieldKind
	key  string
	raw  string // meaning depends on kind: literal value, file path, or env var name
	tag  string // human-readable source, for logs and dry-run output
}

// orderedFields collects --set/--set-prompt/--set-file/--set-env flags in
// the order they appear on the command line, regardless of which of the
// four flag names was used for each occurrence.
type orderedFields struct {
	items *[]fieldSpec
	kind  fieldKind
	label string
}

func (f orderedFields) String() string { return "" }

func (f orderedFields) Set(value string) error {
	if f.kind == fieldPrompt {
		key := strings.TrimSpace(value)
		if key == "" {
			return fmt.Errorf("%s requires a field key", f.label)
		}
		*f.items = append(*f.items, fieldSpec{kind: f.kind, key: key, tag: "prompt"})
		return nil
	}

	key, rest, ok := strings.Cut(value, "=")
	if !ok || key == "" || rest == "" {
		return fmt.Errorf("%s must be in key=%s form, got %q", f.label, valueHint(f.kind), value)
	}

	tag := "literal"
	if f.kind == fieldFile {
		tag = "file:" + rest
	} else if f.kind == fieldEnv {
		tag = "env:" + rest
	}
	*f.items = append(*f.items, fieldSpec{kind: f.kind, key: key, raw: rest, tag: tag})
	return nil
}

func valueHint(kind fieldKind) string {
	switch kind {
	case fieldFile:
		return "path"
	case fieldEnv:
		return "ENV_VAR"
	default:
		return "value"
	}
}

type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }
func (m *multiFlag) Set(value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return fmt.Errorf("value must not be empty")
	}
	*m = append(*m, value)
	return nil
}

func main() {
	var (
		vaultNamespace = flag.String("vault-namespace", "vault", "Namespace running the Vault Pod")
		vaultPod       = flag.String("vault-pod", "vault-0", "Name of the Vault Pod")
		waitTimeout    = flag.String("wait-timeout", "300s", "Timeout passed to every kubectl wait/rollout call")

		mount      = flag.String("mount", "kv", "KV v2 mount path")
		secretPath = flag.String("path", "", "Secret path under the mount, e.g. homeserver/gitea (required)")
		patch      = flag.Bool("patch", false, "Merge fields into the existing secret version instead of overwriting it (fails if the secret does not exist yet)")

		policyName  = flag.String("policy", "", "Policy name to create/update granting read access to this secret path")
		policyCaps  = flag.String("policy-capabilities", "read", "Comma-separated capabilities to grant on the secret path")
		roleName    = flag.String("role", "", "Kubernetes auth role name to create/update")
		audience    = flag.String("audience", "vault", "Audience bound to the Kubernetes auth role")
		roleTTL     = flag.String("role-ttl", "1h", "TTL for tokens issued by the Kubernetes auth role")
		secretStore = flag.String("secretstore", "vault-backend", "SecretStore name to wait on")
		esName      = flag.String("wait-externalsecret", "", "ExternalSecret name to wait for and force-sync after writing the secret")
		appNS       = flag.String("app-namespace", "", "Namespace containing the SecretStore/ExternalSecret/Deployments (required with -wait-externalsecret or -restart)")

		dryRun = flag.Bool("dry-run", false, "Print the plan without contacting Vault or the cluster")
	)

	var boundSAs, boundNamespaces, policyRefs, restarts multiFlag
	flag.Var(&boundSAs, "bound-sa", "ServiceAccount name bound to the role (repeatable)")
	flag.Var(&boundNamespaces, "bound-namespace", "Namespace bound to the role (repeatable)")
	flag.Var(&policyRefs, "policy-ref", "Additional existing policy name to attach to the role (repeatable)")
	flag.Var(&restarts, "restart", "Deployment name to rollout restart after the ExternalSecret syncs (repeatable)")

	var fields []fieldSpec
	flag.Var(orderedFields{items: &fields, kind: fieldLiteral, label: "-set"}, "set", "Field key=value written directly (avoid for real secrets; prefer -set-prompt)")
	flag.Var(orderedFields{items: &fields, kind: fieldPrompt, label: "-set-prompt"}, "set-prompt", "Field key whose value is read from a hidden terminal prompt")
	flag.Var(orderedFields{items: &fields, kind: fieldFile, label: "-set-file"}, "set-file", "Field key=/path/to/file whose value is read from a file")
	flag.Var(orderedFields{items: &fields, kind: fieldEnv, label: "-set-env"}, "set-env", "Field key=ENV_VAR whose value is read from an environment variable")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, `vaultsecret writes/updates a Vault KV v2 secret and the surrounding Kubernetes
auth wiring (policy, role, ExternalSecret sync) that scripts/configure-*.sh
used to hand-roll per integration. Vault is only ever reached through
"kubectl exec" into the Vault Pod, so no network path to Vault is required.

Usage:
  vaultsecret -path homeserver/gitea \
    -set-prompt dbName -set-prompt dbUser -set-prompt dbPassword \
    -policy gitea-db-read -role gitea \
    -bound-sa gitea-vault-auth -bound-namespace gitea \
    -wait-externalsecret gitea-secret -app-namespace gitea

Flags:
`)
		flag.PrintDefaults()
	}

	flag.Parse()

	if *secretPath == "" {
		fail("-path is required")
	}
	if !rePath.MatchString(*secretPath) {
		fail("-path has an invalid format: %s", *secretPath)
	}
	if !reSimpleName.MatchString(*mount) {
		fail("-mount has an invalid format: %s", *mount)
	}
	if len(fields) == 0 {
		fail("at least one -set, -set-prompt, -set-file, or -set-env is required")
	}
	seenKeys := map[string]bool{}
	for _, f := range fields {
		if !reFieldKey.MatchString(f.key) {
			fail("field key %q must match %s", f.key, reFieldKey.String())
		}
		seenKeys[f.key] = true
	}

	caps, err := parseCapabilities(*policyCaps)
	if err != nil {
		fail("%v", err)
	}

	if *policyName != "" && !reSimpleName.MatchString(*policyName) {
		fail("-policy has an invalid format: %s", *policyName)
	}

	var rolePolicies []string
	if *roleName != "" {
		if !reSimpleName.MatchString(*roleName) {
			fail("-role has an invalid format: %s", *roleName)
		}
		if len(boundSAs) == 0 {
			fail("-role requires at least one -bound-sa")
		}
		if len(boundNamespaces) == 0 {
			fail("-role requires at least one -bound-namespace")
		}
		if !reTTL.MatchString(*roleTTL) {
			fail("-role-ttl has an invalid format: %s", *roleTTL)
		}
		if !reSimpleName.MatchString(*audience) {
			fail("-audience has an invalid format: %s", *audience)
		}
		rolePolicies = uniqueStrings(append([]string{}, append([]string{*policyName}, policyRefs...)...))
		if len(rolePolicies) == 0 {
			fail("-role requires -policy and/or -policy-ref")
		}
		for _, n := range append(append([]string{}, boundSAs...), boundNamespaces...) {
			if !reSimpleName.MatchString(n) {
				fail("-bound-sa/-bound-namespace has an invalid format: %s", n)
			}
		}
		for _, n := range rolePolicies {
			if !reSimpleName.MatchString(n) {
				fail("-policy/-policy-ref has an invalid format: %s", n)
			}
		}
	}

	if *esName != "" && !reSimpleName.MatchString(*esName) {
		fail("-wait-externalsecret has an invalid format: %s", *esName)
	}
	if !reSimpleName.MatchString(*secretStore) {
		fail("-secretstore has an invalid format: %s", *secretStore)
	}
	if (*esName != "" || len(restarts) > 0) && *appNS == "" {
		fail("-app-namespace is required with -wait-externalsecret or -restart")
	}
	if *appNS != "" && !reSimpleName.MatchString(*appNS) {
		fail("-app-namespace has an invalid format: %s", *appNS)
	}
	for _, d := range restarts {
		if !reSimpleName.MatchString(d) {
			fail("-restart has an invalid format: %s", d)
		}
	}

	if *dryRun {
		printPlan(*mount, *secretPath, *patch, fields, *policyName, caps, *roleName, boundSAs, boundNamespaces, *audience, rolePolicies, *roleTTL, *esName, *secretStore, *appNS, restarts)
		return
	}

	log("Waiting for the Vault pod")
	requireVaultReady(*vaultNamespace, *vaultPod, *waitTimeout)

	rootToken := resolveRootToken()

	log("Resolving secret field values")
	resolved, err := resolveFields(fields)
	if err != nil {
		fail("%v", err)
	}

	log("Writing to Vault through kubectl exec")
	script := buildRemoteScript(*mount, *secretPath, *patch, resolved, *policyName, caps, *roleName, boundSAs, boundNamespaces, *audience, rolePolicies, *roleTTL)
	if err := runVaultShell(*vaultNamespace, *vaultPod, script, rootToken, resolved); err != nil {
		fail("Vault write failed: %v", err)
	}
	zeroString(&rootToken)
	for i := range resolved {
		zeroString(&resolved[i].value)
	}

	if *esName != "" {
		log("Waiting for External Secrets to sync %s/%s", *appNS, *esName)
		waitForExternalSecret(*secretStore, *esName, *appNS, *waitTimeout)
	}

	for _, d := range restarts {
		log("Restarting deployment/%s in %s", d, *appNS)
		must(runKubectl("rollout", "restart", "deployment/"+d, "-n", *appNS))
		must(runKubectl("rollout", "status", "deployment/"+d, "-n", *appNS, "--timeout="+*waitTimeout))
	}

	log("Done: %s/%s updated", *mount, *secretPath)
}

// resolvedField holds a field key alongside its resolved value, kept
// separate from fieldSpec so values never linger in the flag-parsing
// structures longer than necessary.
type resolvedField struct {
	key   string
	value string
}

func resolveFields(fields []fieldSpec) ([]resolvedField, error) {
	out := make([]resolvedField, 0, len(fields))
	for _, f := range fields {
		var value string
		switch f.kind {
		case fieldLiteral:
			value = f.raw
		case fieldFile:
			data, err := os.ReadFile(f.raw)
			if err != nil {
				return nil, fmt.Errorf("reading %s for field %s: %w", f.raw, f.key, err)
			}
			value = strings.TrimRight(string(data), "\r\n")
		case fieldEnv:
			v, ok := os.LookupEnv(f.raw)
			if !ok {
				return nil, fmt.Errorf("environment variable %s is not set (field %s)", f.raw, f.key)
			}
			value = v
		case fieldPrompt:
			v, err := readSecret(fmt.Sprintf("%s: ", f.key))
			if err != nil {
				return nil, fmt.Errorf("reading value for field %s: %w", f.key, err)
			}
			value = v
		}
		if strings.ContainsAny(value, "\n\r") {
			return nil, fmt.Errorf("field %s contains a newline, which this tool cannot transmit safely", f.key)
		}
		if value == "" {
			return nil, fmt.Errorf("field %s resolved to an empty value", f.key)
		}
		out = append(out, resolvedField{key: f.key, value: value})
	}
	return out, nil
}

func resolveRootToken() string {
	if v := os.Getenv("VAULT_ROOT_TOKEN"); v != "" {
		return v
	}
	token, err := readSecret("Vault root token: ")
	if err != nil {
		fail("reading Vault root token: %v", err)
	}
	if token == "" {
		fail("Vault root token cannot be empty")
	}
	return token
}

func parseCapabilities(spec string) ([]string, error) {
	parts := strings.Split(spec, ",")
	seen := map[string]bool{}
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if !allowedCapSet[p] {
			return nil, fmt.Errorf("unknown capability %q", p)
		}
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("-policy-capabilities must list at least one capability")
	}
	sort.Strings(out)
	return out, nil
}

func formatCapabilities(caps []string) string {
	quoted := make([]string, len(caps))
	for i, c := range caps {
		quoted[i] = `"` + c + `"`
	}
	return "[" + strings.Join(quoted, ", ") + "]"
}

func uniqueStrings(in []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if s == "" || seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

// buildRemoteScript composes the POSIX sh script executed inside the Vault
// Pod. It mirrors the body of scripts/configure-*.sh but is generic over an
// arbitrary field set, policy, and role. All identifiers embedded here have
// already been validated against a restrictive allow-list in main(), and all
// secret material is read from stdin at runtime via "IFS= read -r" rather
// than being embedded in the script text.
func buildRemoteScript(mount, secretPath string, patch bool, fields []resolvedField, policyName string, caps []string, roleName string, boundSAs, boundNamespaces multiFlag, audience string, rolePolicies []string, roleTTL string) string {
	var sb strings.Builder

	sb.WriteString("IFS= read -r VAULT_TOKEN\n")
	for _, f := range fields {
		fmt.Fprintf(&sb, "IFS= read -r V_%s\n", f.key)
	}
	fmt.Fprintf(&sb, "export VAULT_ADDR=%q\n", vaultAddr)
	sb.WriteString("export VAULT_TOKEN\n\n")
	sb.WriteString("vault token lookup >/dev/null\n")
	fmt.Fprintf(&sb, "vault secrets list -format=json | grep -q \"\\\"%s/\\\"\" || { printf \"KV v2 is not enabled at %s/\\n\" >&2; exit 1; }\n", mount, mount)

	if roleName != "" {
		sb.WriteString("vault auth list -format=json | grep -q \"\\\"kubernetes/\\\"\" || { printf \"Kubernetes auth is not enabled at kubernetes/\\n\" >&2; exit 1; }\n")
	}

	if policyName != "" {
		capStr := formatCapabilities(caps)
		fmt.Fprintf(&sb, "\nvault policy write %s - >/dev/null <<'POLICY'\npath \"%s/data/%s\" {\n  capabilities = %s\n}\n\npath \"%s/metadata/%s\" {\n  capabilities = %s\n}\nPOLICY\n",
			policyName, mount, secretPath, capStr, mount, secretPath, capStr)
	}

	if roleName != "" {
		fmt.Fprintf(&sb, "\nvault write auth/kubernetes/role/%s \\\n  bound_service_account_names=%s \\\n  bound_service_account_namespaces=%s \\\n  audience=%s \\\n  policies=%s \\\n  ttl=%s >/dev/null\n",
			roleName, strings.Join(boundSAs, ","), strings.Join(boundNamespaces, ","), audience, strings.Join(rolePolicies, ","), roleTTL)
	}

	verb := "put"
	if patch {
		verb = "patch"
	}
	fmt.Fprintf(&sb, "\nvault kv %s -mount=%s %s", verb, mount, secretPath)
	for _, f := range fields {
		fmt.Fprintf(&sb, " \\\n  %s=\"$V_%s\"", f.key, f.key)
	}
	sb.WriteString(" >/dev/null\n\nunset VAULT_TOKEN")
	for _, f := range fields {
		fmt.Fprintf(&sb, " V_%s", f.key)
	}
	sb.WriteString("\n")

	return sb.String()
}

func runVaultShell(vaultNamespace, vaultPod, script, rootToken string, fields []resolvedField) error {
	var stdin strings.Builder
	stdin.WriteString(rootToken)
	stdin.WriteString("\n")
	for _, f := range fields {
		stdin.WriteString(f.value)
		stdin.WriteString("\n")
	}

	cmd := exec.Command("kubectl", "exec", "-i", "-n", vaultNamespace, vaultPod, "--", "sh", "-ec", script)
	cmd.Stdin = strings.NewReader(stdin.String())
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

type vaultStatus struct {
	Initialized bool `json:"initialized"`
	Sealed      bool `json:"sealed"`
}

func requireVaultReady(vaultNamespace, vaultPod, waitTimeout string) {
	if err := runKubectl("get", "pod", vaultPod, "-n", vaultNamespace); err != nil {
		fail("Vault is not deployed; run deploy.sh first")
	}
	must(runKubectl("wait", "pod/"+vaultPod, "-n", vaultNamespace,
		"--for=jsonpath={.status.phase}=Running", "--timeout="+waitTimeout))

	out, err := kubectlOutput("exec", "-n", vaultNamespace, vaultPod, "--",
		"env", "VAULT_ADDR="+vaultAddr, "vault", "status", "-format=json")
	if err != nil {
		fail("Unable to read Vault status from %s/%s: %v", vaultNamespace, vaultPod, err)
	}
	var status vaultStatus
	if err := json.Unmarshal([]byte(out), &status); err != nil {
		fail("Vault returned invalid status JSON: %v", err)
	}
	if !status.Initialized {
		fail("Vault is not initialized; run scripts/bootstrap-vault.sh first")
	}
	if status.Sealed {
		fail("Vault is sealed; run scripts/unseal-vault.sh first")
	}
}

func waitForExternalSecret(secretStore, esName, appNS, waitTimeout string) {
	must(runKubectl("wait", "--for=create", "secretstore/"+secretStore, "-n", appNS, "--timeout="+waitTimeout))
	must(runKubectl("wait", "--for=create", "externalsecret/"+esName, "-n", appNS, "--timeout="+waitTimeout))
	must(runKubectl("annotate", "externalsecret", esName, "-n", appNS,
		"external-secrets.io/force-sync="+timestampNow(), "--overwrite"))
	must(runKubectl("wait", "secretstore/"+secretStore, "-n", appNS, "--for=condition=Ready", "--timeout="+waitTimeout))
	must(runKubectl("wait", "externalsecret/"+esName, "-n", appNS, "--for=condition=Ready", "--timeout="+waitTimeout))
}

func timestampNow() string {
	out, err := exec.Command("date", "+%s").Output()
	if err != nil {
		fail("computing timestamp: %v", err)
	}
	return strings.TrimSpace(string(out))
}

func runKubectl(args ...string) error {
	cmd := exec.Command("kubectl", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func kubectlOutput(args ...string) (string, error) {
	cmd := exec.Command("kubectl", args...)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

func must(err error) {
	if err != nil {
		fail("%v", err)
	}
}

func log(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "\n==> "+format+"\n", args...)
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "ERROR: "+format+"\n", args...)
	os.Exit(1)
}

func zeroString(s *string) {
	*s = ""
}

// readSecret prompts on the controlling terminal with echo disabled,
// mirroring bash's `read -r -s`. It falls back to a plain (echoed) read from
// stdin when no controlling terminal is available, e.g. when piped in CI.
func readSecret(prompt string) (string, error) {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fmt.Fprint(os.Stderr, prompt)
		line, rerr := bufio.NewReader(os.Stdin).ReadString('\n')
		if rerr != nil && rerr != io.EOF {
			return "", rerr
		}
		return strings.TrimRight(line, "\r\n"), nil
	}
	defer tty.Close()

	fmt.Fprint(os.Stderr, prompt)

	off := exec.Command("stty", "-echo")
	off.Stdin = tty
	if err := off.Run(); err != nil {
		return "", fmt.Errorf("stty -echo: %w", err)
	}
	defer func() {
		on := exec.Command("stty", "echo")
		on.Stdin = tty
		_ = on.Run()
		fmt.Fprintln(os.Stderr)
	}()

	line, err := bufio.NewReader(tty).ReadString('\n')
	if err != nil && err != io.EOF {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

func printPlan(mount, secretPath string, patch bool, fields []fieldSpec, policyName string, caps []string, roleName string, boundSAs, boundNamespaces multiFlag, audience string, rolePolicies []string, roleTTL string, esName, secretStore, appNS string, restarts multiFlag) {
	verb := "put (overwrite)"
	if patch {
		verb = "patch (merge)"
	}
	fmt.Printf("Plan (dry run, nothing was contacted):\n\n")
	fmt.Printf("  secret:   %s/%s\n", mount, secretPath)
	fmt.Printf("  mode:     %s\n", verb)
	fmt.Printf("  fields:\n")
	for _, f := range fields {
		fmt.Printf("    - %s  (source: %s)\n", f.key, f.tag)
	}
	if policyName != "" {
		fmt.Printf("  policy:   %s  capabilities=%s on %s/data/%s and %s/metadata/%s\n",
			policyName, formatCapabilities(caps), mount, secretPath, mount, secretPath)
	}
	if roleName != "" {
		fmt.Printf("  role:     %s\n", roleName)
		fmt.Printf("    bound_service_account_names=%s\n", strings.Join(boundSAs, ","))
		fmt.Printf("    bound_service_account_namespaces=%s\n", strings.Join(boundNamespaces, ","))
		fmt.Printf("    audience=%s  policies=%s  ttl=%s\n", audience, strings.Join(rolePolicies, ","), roleTTL)
	}
	if esName != "" {
		fmt.Printf("  sync:     wait for secretstore/%s and externalsecret/%s in namespace %s, then force-sync\n", secretStore, esName, appNS)
	}
	for _, d := range restarts {
		fmt.Printf("  restart:  deployment/%s in namespace %s\n", d, appNS)
	}
}
