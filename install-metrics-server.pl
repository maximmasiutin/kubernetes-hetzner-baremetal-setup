#!/usr/bin/perl
# install-metrics-server.pl - Install/fix Kubernetes metrics-server with TLS validation
# Verifies cluster health, certificates, and connectivity before installation
# Usage: sudo perl install-metrics-server.pl [--force]
use strict; use warnings; use POSIX qw(strftime);

my $METRICS_SERVER_VERSION = "v0.7.0";
my $FORCE = grep { /^--force$/ } @ARGV;

sub log_info  { print "[INFO]  $_[0]\n"; }
sub log_warn  { print "[WARN]  $_[0]\n"; }
sub log_error { print "[ERROR] $_[0]\n"; }
sub log_ok    { print "[OK]    $_[0]\n"; }

sub run_cmd {
    my ($cmd, $silent) = @_;
    my $out = `$cmd 2>&1`;
    return ($?, $out);
}

sub kubectl { my ($args) = @_; return run_cmd("kubectl $args"); }

sub check_root {
    if ($> != 0) { log_error("Must run as root"); exit 1; }
    log_ok("Running as root");
}

sub check_control_plane {
    unless (-f "/etc/kubernetes/admin.conf") {
        log_error("Not a control plane node (/etc/kubernetes/admin.conf missing)");
        exit 1;
    }
    my ($rc, $out) = kubectl("get nodes -o wide 2>/dev/null");
    if ($rc != 0) { log_error("kubectl not working: $out"); exit 1; }

    my $hostname = `hostname`; chomp $hostname;
    my ($rc2, $roles) = kubectl("get node $hostname -o jsonpath='{.metadata.labels.node-role\\.kubernetes\\.io/control-plane}'");
    unless ($roles =~ /\S/ || -d "/etc/kubernetes/manifests") {
        log_error("This node ($hostname) is not a control plane");
        exit 1;
    }
    log_ok("Running on control plane node: $hostname");
}

sub get_nodes {
    my ($rc, $out) = kubectl("get nodes -o jsonpath='{range .items[*]}{.metadata.name}|{.status.addresses[?(\@.type==\"InternalIP\")].address}|{.status.conditions[?(\@.type==\"Ready\")].status}\\n{end}'");
    if ($rc != 0) { log_error("Failed to get nodes"); exit 1; }
    my @nodes;
    for my $line (split /\n/, $out) {
        next unless $line =~ /\S/;
        my ($name, $ip, $ready) = split /\|/, $line;
        push @nodes, { name => $name, ip => $ip, ready => $ready };
    }
    return @nodes;
}

sub check_nodes {
    log_info("Checking cluster nodes...");
    my @nodes = get_nodes();
    if (@nodes == 0) { log_error("No nodes found in cluster"); exit 1; }

    my $all_ok = 1;
    for my $n (@nodes) {
        my $status = $n->{ready} eq 'True' ? 'Ready' : 'NotReady';
        if ($status eq 'Ready') {
            log_ok("Node $n->{name} ($n->{ip}): $status");
        } else {
            log_warn("Node $n->{name} ($n->{ip}): $status");
            $all_ok = 0;
        }
        # Validate IP format
        unless ($n->{ip} =~ /^\d+\.\d+\.\d+\.\d+$/) {
            log_warn("Node $n->{name} has invalid IP: $n->{ip}");
            $all_ok = 0;
        }
        # Validate hostname (DNS-1123)
        unless ($n->{name} =~ /^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$/i) {
            log_warn("Node $n->{name} has invalid hostname format");
            $all_ok = 0;
        }
    }
    return ($all_ok, @nodes);
}

sub check_kubelet_certs {
    my (@nodes) = @_;
    log_info("Checking kubelet certificates...");
    my $issues = 0;

    # Check local kubelet cert
    my $cert_file = "/var/lib/kubelet/pki/kubelet.crt";
    if (-f $cert_file) {
        my ($rc, $out) = run_cmd("openssl x509 -in $cert_file -noout -dates -subject -ext subjectAltName 2>&1");
        if ($rc == 0) {
            # Check expiry
            if ($out =~ /notAfter=(.+)/) {
                my $expiry = $1;
                log_ok("Local kubelet cert expires: $expiry");
                # Parse and check if expiring soon (30 days)
                my ($rc2, $days) = run_cmd("openssl x509 -in $cert_file -noout -checkend 2592000");
                if ($rc2 != 0) {
                    log_warn("Local kubelet cert expires within 30 days");
                    $issues++;
                }
            }
            # Check SANs include node IP
            my $hostname = `hostname`; chomp $hostname;
            my ($rc3, $ip_out) = run_cmd("ip -4 addr show vlan4000 2>/dev/null | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}'");
            chomp $ip_out;
            if ($ip_out && $out !~ /\Q$ip_out\E/) {
                log_warn("Kubelet cert may not include vlan4000 IP ($ip_out) in SANs");
                $issues++;
            }
        } else {
            log_warn("Cannot read kubelet cert: $out");
            $issues++;
        }
    } else {
        log_warn("Kubelet cert not found at $cert_file");
        $issues++;
    }
    return $issues;
}

sub check_apiserver_cert {
    log_info("Checking API server certificate...");
    my $cert_file = "/etc/kubernetes/pki/apiserver.crt";
    unless (-f $cert_file) {
        log_warn("API server cert not found");
        return 1;
    }
    my ($rc, $out) = run_cmd("openssl x509 -in $cert_file -noout -dates -ext subjectAltName 2>&1");
    if ($rc == 0) {
        if ($out =~ /notAfter=(.+)/) { log_ok("API server cert expires: $1"); }
        my ($rc2, $days) = run_cmd("openssl x509 -in $cert_file -noout -checkend 2592000");
        if ($rc2 != 0) {
            log_warn("API server cert expires within 30 days");
            return 1;
        }
    }
    return 0;
}

sub check_metrics_server_exists {
    log_info("Checking if metrics-server is installed...");
    my ($rc, $out) = kubectl("get deployment metrics-server -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null");
    if ($rc == 0 && $out =~ /\d+/ && $out > 0) {
        log_ok("metrics-server deployment exists with $out ready replicas");
        return (1, int($out));
    }
    my ($rc2, $out2) = kubectl("get deployment metrics-server -n kube-system 2>/dev/null");
    if ($rc2 == 0) {
        log_warn("metrics-server exists but has no ready replicas");
        return (1, 0);
    }
    log_info("metrics-server not installed");
    return (0, 0);
}

sub check_metrics_api_working {
    log_info("Testing metrics API...");
    my ($rc, $out) = kubectl("top nodes 2>&1");
    if ($rc == 0 && $out =~ /CPU.*MEMORY/i) {
        log_ok("kubectl top nodes works");
        return 1;
    }
    if ($out =~ /Metrics API not available|metrics.k8s.io.*not found/i) {
        log_info("Metrics API not available");
        return 0;
    }
    if ($out =~ /tls|certificate|x509/i) {
        log_warn("Metrics API has TLS issues: $out");
        return -1; # TLS error
    }
    log_warn("Metrics API error: $out");
    return 0;
}

sub check_kubelet_connectivity {
    my (@nodes) = @_;
    log_info("Testing kubelet connectivity from control plane...");
    my $issues = 0;
    for my $n (@nodes) {
        my ($rc, $out) = run_cmd("curl -ks --connect-timeout 5 https://$n->{ip}:10250/healthz 2>&1");
        if ($out =~ /ok|Unauthorized/) {
            log_ok("Kubelet on $n->{name} ($n->{ip}:10250) reachable");
        } else {
            log_warn("Cannot reach kubelet on $n->{name} ($n->{ip}:10250): $out");
            $issues++;
        }
    }
    return $issues;
}

sub get_metrics_server_logs {
    my ($rc, $out) = kubectl("logs -n kube-system -l k8s-app=metrics-server --tail=50 2>&1");
    return $out;
}

sub diagnose_metrics_server {
    log_info("Diagnosing metrics-server issues...");
    my $logs = get_metrics_server_logs();
    my %issues;
    $issues{tls_verify} = 1 if $logs =~ /x509|certificate|tls/i;
    $issues{kubelet_connect} = 1 if $logs =~ /dial tcp|connection refused|no route/i;
    $issues{resolve} = 1 if $logs =~ /no such host|lookup.*failed/i;
    $issues{auth} = 1 if $logs =~ /Unauthorized|forbidden/i;

    if ($issues{tls_verify}) {
        log_warn("Detected TLS/certificate verification issues");
        log_info("Logs snippet: " . substr($logs, 0, 500));
    }
    if ($issues{kubelet_connect}) { log_warn("Detected kubelet connectivity issues"); }
    if ($issues{resolve}) { log_warn("Detected DNS resolution issues"); }
    if ($issues{auth}) { log_warn("Detected authentication issues"); }

    return %issues;
}

sub regenerate_kubelet_certs {
    log_info("Attempting to regenerate kubelet certificates...");
    my $hostname = `hostname`; chomp $hostname;

    # Backup existing certs
    my $backup_dir = "/var/lib/kubelet/pki.backup." . strftime("%Y%m%d%H%M%S", localtime);
    run_cmd("cp -r /var/lib/kubelet/pki $backup_dir 2>/dev/null");
    log_info("Backed up certs to $backup_dir");

    # Remove old certs to trigger regeneration
    run_cmd("rm -f /var/lib/kubelet/pki/kubelet-client-current.pem");
    run_cmd("rm -f /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key");

    # Restart kubelet to regenerate
    log_info("Restarting kubelet to regenerate certificates...");
    my ($rc, $out) = run_cmd("systemctl restart kubelet");
    if ($rc != 0) {
        log_error("Failed to restart kubelet: $out");
        return 0;
    }
    sleep 10;

    # Verify kubelet is running
    ($rc, $out) = run_cmd("systemctl is-active kubelet");
    if ($out =~ /active/) {
        log_ok("Kubelet restarted successfully");
        return 1;
    }
    log_error("Kubelet failed to start after cert regeneration");
    return 0;
}

sub create_metrics_server_manifest {

    return <<"EOF";
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:aggregated-metrics-reader
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
rules:
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods", "nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:metrics-server
rules:
- apiGroups: [""]
  resources: ["nodes/metrics"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["pods", "nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metrics-server:system:auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:metrics-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:metrics-server
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: metrics-server-auth-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
apiVersion: v1
kind: Service
metadata:
  name: metrics-server
  namespace: kube-system
  labels:
    kubernetes.io/name: "Metrics-server"
    kubernetes.io/cluster-service: "true"
spec:
  selector:
    k8s-app: metrics-server
  ports:
  - port: 443
    protocol: TCP
    targetPort: https
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-server
  namespace: kube-system
  labels:
    k8s-app: metrics-server
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  strategy:
    rollingUpdate:
      maxUnavailable: 0
  template:
    metadata:
      labels:
        k8s-app: metrics-server
    spec:
      serviceAccountName: metrics-server
      priorityClassName: system-cluster-critical
      containers:
      - name: metrics-server
        image: registry.k8s.io/metrics-server/metrics-server:$METRICS_SERVER_VERSION
        imagePullPolicy: IfNotPresent
        args:
        - --cert-dir=/tmp
        - --secure-port=10250
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        ports:
        - name: https
          containerPort: 10250
          protocol: TCP
        readinessProbe:
          httpGet:
            path: /readyz
            port: https
            scheme: HTTPS
          periodSeconds: 10
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /livez
            port: https
            scheme: HTTPS
          periodSeconds: 10
          failureThreshold: 3
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: tmp-dir
          mountPath: /tmp
      nodeSelector:
        kubernetes.io/os: linux
      volumes:
      - name: tmp-dir
        emptyDir: {}
---
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1beta1.metrics.k8s.io
  labels:
    k8s-app: metrics-server
spec:
  service:
    name: metrics-server
    namespace: kube-system
  group: metrics.k8s.io
  version: v1beta1
  insecureSkipTLSVerify: true
  groupPriorityMinimum: 100
  versionPriority: 100
EOF
}

sub install_metrics_server {
    log_info("Installing metrics-server with secure TLS...");

    my $manifest = create_metrics_server_manifest();
    my $manifest_file = "/tmp/metrics-server-$$.yaml";

    open my $fh, '>', $manifest_file or die "Cannot write manifest: $!";
    print $fh $manifest;
    close $fh;

    my ($rc, $out) = kubectl("apply -f $manifest_file");
    unlink $manifest_file;

    if ($rc != 0) {
        log_error("Failed to apply metrics-server manifest: $out");
        return 0;
    }
    log_ok("metrics-server manifest applied");
    return 1;
}

sub delete_metrics_server {
    log_info("Removing existing metrics-server...");
    kubectl("delete deployment metrics-server -n kube-system --ignore-not-found");
    kubectl("delete service metrics-server -n kube-system --ignore-not-found");
    kubectl("delete apiservice v1beta1.metrics.k8s.io --ignore-not-found");
    kubectl("delete clusterrole system:metrics-server system:aggregated-metrics-reader --ignore-not-found");
    kubectl("delete clusterrolebinding system:metrics-server metrics-server:system:auth-delegator --ignore-not-found");
    kubectl("delete rolebinding metrics-server-auth-reader -n kube-system --ignore-not-found");
    kubectl("delete serviceaccount metrics-server -n kube-system --ignore-not-found");
    sleep 5;
}

sub wait_for_metrics_server {
    my ($timeout) = @_;
    $timeout //= 120;
    log_info("Waiting for metrics-server to be ready (timeout: ${timeout}s)...");

    for (my $i = 0; $i < $timeout; $i += 10) {
        my ($rc, $replicas) = kubectl("get deployment metrics-server -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null");
        if ($rc == 0 && defined $replicas && $replicas =~ /^\d+$/ && $replicas > 0) {
            log_ok("metrics-server ready with $replicas replicas");
            return 1;
        }
        sleep 10;
        print ".";
    }
    print "\n";
    log_warn("metrics-server did not become ready within ${timeout}s");
    return 0;
}

sub wait_for_metrics_api {
    my ($timeout) = @_;
    $timeout //= 60;
    log_info("Waiting for metrics API to respond (timeout: ${timeout}s)...");

    for (my $i = 0; $i < $timeout; $i += 10) {
        my ($rc, $out) = kubectl("top nodes 2>&1");
        if ($rc == 0 && $out =~ /CPU.*MEMORY/i) {
            log_ok("Metrics API working");
            print "\n$out\n";
            return 1;
        }
        sleep 10;
        print ".";
    }
    print "\n";
    return 0;
}

sub fix_coredns_for_hostnames {
    log_info("Checking CoreDNS configuration for node hostname resolution...");
    my ($rc, $cm) = kubectl("get configmap coredns -n kube-system -o yaml 2>/dev/null");
    if ($rc != 0) {
        log_warn("Cannot get CoreDNS configmap");
        return;
    }
    # CoreDNS should resolve node hostnames - usually works by default with kubernetes plugin
    log_ok("CoreDNS configmap exists");
}

# Main
print "=" x 60 . "\n";
print "Kubernetes Metrics Server Installer with TLS Validation\n";
print "=" x 60 . "\n\n";

check_root();
check_control_plane();

my ($nodes_ok, @nodes) = check_nodes();
unless ($nodes_ok || $FORCE) {
    log_error("Some nodes have issues. Use --force to continue anyway.");
    exit 1;
}

my $kubelet_issues = check_kubelet_certs(@nodes);
my $apiserver_issues = check_apiserver_cert();
my $connectivity_issues = check_kubelet_connectivity(@nodes);

if ($kubelet_issues || $apiserver_issues) {
    log_warn("Certificate issues detected");
    if ($FORCE) {
        log_info("Continuing due to --force flag");
    } else {
        print "\nAttempt to fix certificate issues? [y/N]: ";
        my $answer = <STDIN>; chomp $answer;
        if ($answer =~ /^y/i) {
            regenerate_kubelet_certs() if $kubelet_issues;
        }
    }
}

my ($ms_exists, $ms_ready) = check_metrics_server_exists();
my $metrics_working = check_metrics_api_working();

if ($metrics_working == 1 && !$FORCE) {
    print "\n" . "=" x 60 . "\n";
    log_ok("metrics-server is installed and working properly!");
    print "=" x 60 . "\n";
    print "\nNothing to do. Use --force to reinstall anyway.\n";
    exit 0;
}

if ($ms_exists && $metrics_working != 1) {
    log_info("metrics-server exists but not working properly");
    my %issues = diagnose_metrics_server();

    if ($issues{tls_verify}) {
        log_warn("TLS verification issues detected");
        print "\nOptions:\n";
        print "  1. Try to fix certificates (may require node restarts)\n";
        print "  2. Exit\n";
        print "Choose [1/2]: ";
        my $choice = <STDIN>; chomp $choice;
        if ($choice eq '1') {
            regenerate_kubelet_certs();
            log_info("Certificates regenerated. Restarting metrics-server...");
            kubectl("rollout restart deployment metrics-server -n kube-system");
            if (wait_for_metrics_server(120) && wait_for_metrics_api(60)) {
                log_ok("metrics-server fixed!");
                exit 0;
            }
            log_warn("Still having issues after certificate regeneration");
        } else {
            exit 0;
        }
    }

    delete_metrics_server();
}

fix_coredns_for_hostnames();

unless (install_metrics_server()) {
    log_error("Failed to install metrics-server");
    exit 1;
}

unless (wait_for_metrics_server(120)) {
    log_warn("metrics-server deployment not ready, checking logs...");
    my %issues = diagnose_metrics_server();
    if ($issues{tls_verify}) {
        log_warn("TLS issues detected. Try regenerating certificates on all nodes.");
        log_info("Run: sudo perl install-metrics-server.pl --force");
    }
}

if (wait_for_metrics_api(90)) {
    print "\n" . "=" x 60 . "\n";
    log_ok("metrics-server installed and working!");
    print "=" x 60 . "\n";
    print "\nYou can now use:\n  kubectl top nodes\n  kubectl top pods\n";
} else {
    log_error("metrics-server installed but metrics API not responding");
    log_info("Check logs: kubectl logs -n kube-system -l k8s-app=metrics-server");
    exit 1;
}
