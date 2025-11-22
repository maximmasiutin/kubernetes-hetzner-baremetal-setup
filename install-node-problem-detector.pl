#!/usr/bin/perl
# install-node-problem-detector.pl - Install Kubernetes Node Problem Detector
# Detects node problems: kernel issues, filesystem corruption, container runtime issues
# Usage: sudo perl install-node-problem-detector.pl [--force] [--uninstall]
use strict; use warnings;

my $NPD_VERSION = "v0.8.19";
my $NPD_IMAGE = "registry.k8s.io/node-problem-detector/node-problem-detector:$NPD_VERSION";
my $FORCE = grep { /^--force$/ } @ARGV;
my $UNINSTALL = grep { /^--uninstall$/ } @ARGV;

sub log_info  { print "[INFO]  $_[0]\n"; }
sub log_warn  { print "[WARN]  $_[0]\n"; }
sub log_error { print "[ERROR] $_[0]\n"; }
sub log_ok    { print "[OK]    $_[0]\n"; }

sub run_cmd { my ($cmd) = @_; my $out = `$cmd 2>&1`; return ($?, $out); }
sub kubectl { my ($args) = @_; return run_cmd("kubectl $args"); }

sub check_root {
    if ($> != 0) { log_error("Must run as root"); exit 1; }
    log_ok("Running as root");
}

sub check_control_plane {
    unless (-f "/etc/kubernetes/admin.conf") {
        log_error("Not a control plane node");
        exit 1;
    }
    my ($rc, $out) = kubectl("cluster-info 2>/dev/null");
    if ($rc != 0) { log_error("kubectl not working"); exit 1; }
    log_ok("Running on control plane, kubectl working");
}

sub check_npd_exists {
    log_info("Checking if node-problem-detector is installed...");
    my ($rc, $out) = kubectl("get daemonset node-problem-detector -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null");
    if ($rc == 0 && $out =~ /\d+/) {
        my $ready = int($out);
        my ($rc2, $desired) = kubectl("get daemonset node-problem-detector -n kube-system -o jsonpath='{.status.desiredNumberScheduled}'");
        $desired = int($desired // 0);
        log_ok("node-problem-detector installed: $ready/$desired nodes ready");
        return (1, $ready, $desired);
    }
    log_info("node-problem-detector not installed");
    return (0, 0, 0);
}

sub check_npd_working {
    log_info("Checking node conditions from NPD...");
    my ($rc, $out) = kubectl("get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions[?(\@.type==\"KernelDeadlock\")].status}\\n{end}' 2>/dev/null");
    if ($rc == 0 && $out =~ /False|True/) {
        log_ok("NPD conditions visible on nodes");
        return 1;
    }
    # Check if conditions exist at all
    ($rc, $out) = kubectl("get nodes -o json 2>/dev/null");
    if ($out =~ /KernelDeadlock|ReadonlyFilesystem|FrequentKubeletRestart/) {
        log_ok("NPD conditions found in node status");
        return 1;
    }
    log_info("NPD conditions not yet visible (may take a minute)");
    return 0;
}

sub get_npd_logs {
    my ($rc, $out) = kubectl("logs -n kube-system -l app=node-problem-detector --tail=20 2>&1");
    return $out;
}

sub uninstall_npd {
    log_info("Uninstalling node-problem-detector...");
    kubectl("delete daemonset node-problem-detector -n kube-system --ignore-not-found");
    kubectl("delete configmap node-problem-detector-config -n kube-system --ignore-not-found");
    kubectl("delete serviceaccount node-problem-detector -n kube-system --ignore-not-found");
    kubectl("delete clusterrole node-problem-detector --ignore-not-found");
    kubectl("delete clusterrolebinding node-problem-detector --ignore-not-found");
    sleep 3;
    log_ok("node-problem-detector uninstalled");
}

sub create_npd_manifest {
    return <<"EOF";
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-problem-detector
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-problem-detector
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["nodes/status"]
  verbs: ["patch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: node-problem-detector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: node-problem-detector
subjects:
- kind: ServiceAccount
  name: node-problem-detector
  namespace: kube-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-problem-detector-config
  namespace: kube-system
data:
  kernel-monitor.json: |
    {
      "plugin": "kmsg",
      "logPath": "/dev/kmsg",
      "lookback": "5m",
      "bufferSize": 10,
      "source": "kernel-monitor",
      "conditions": [
        {
          "type": "KernelDeadlock",
          "reason": "KernelHasNoDeadlock",
          "message": "kernel has no deadlock"
        },
        {
          "type": "ReadonlyFilesystem",
          "reason": "FilesystemIsNotReadOnly",
          "message": "Filesystem is not read-only"
        }
      ],
      "rules": [
        {
          "type": "temporary",
          "reason": "OOMKilling",
          "pattern": "Killed process \\\\d+ \\\\(.+\\\\) total-vm:\\\\d+kB, anon-rss:\\\\d+kB, file-rss:\\\\d+kB.*"
        },
        {
          "type": "temporary",
          "reason": "TaskHung",
          "pattern": "task \\\\S+:\\\\w+ blocked for more than \\\\w+ seconds\\\\."
        },
        {
          "type": "temporary",
          "reason": "UnregisterNetDevice",
          "pattern": "unregister_netdevice: waiting for \\\\w+ to become free"
        },
        {
          "type": "temporary",
          "reason": "KernelOops",
          "pattern": "BUG: unable to handle kernel"
        },
        {
          "type": "temporary",
          "reason": "KernelOops",
          "pattern": "divide error: 0000"
        },
        {
          "type": "permanent",
          "condition": "KernelDeadlock",
          "reason": "AUFSUmountHung",
          "pattern": "task umount\\\\.aufs:\\\\w+ blocked for more than \\\\w+ seconds\\\\."
        },
        {
          "type": "permanent",
          "condition": "KernelDeadlock",
          "reason": "DockerHung",
          "pattern": "task docker:\\\\w+ blocked for more than \\\\w+ seconds\\\\."
        },
        {
          "type": "permanent",
          "condition": "ReadonlyFilesystem",
          "reason": "FilesystemIsReadOnly",
          "pattern": "Remounting filesystem read-only"
        }
      ]
    }
  docker-monitor.json: |
    {
      "plugin": "journald",
      "pluginConfig": {
        "source": "docker"
      },
      "logPath": "/var/log/journal",
      "lookback": "5m",
      "bufferSize": 10,
      "source": "docker-monitor",
      "conditions": [],
      "rules": [
        {
          "type": "temporary",
          "reason": "CorruptDockerImage",
          "pattern": "Error trying v2 registry: failed to register layer: rename /var/lib/docker/image/(.+) /var/lib/docker/image/(.+): directory not empty.*"
        }
      ]
    }
  systemd-monitor.json: |
    {
      "plugin": "journald",
      "pluginConfig": {
        "source": "systemd"
      },
      "logPath": "/var/log/journal",
      "lookback": "5m",
      "bufferSize": 10,
      "source": "systemd-monitor",
      "conditions": [
        {
          "type": "FrequentKubeletRestart",
          "reason": "KubeletIsHealthy",
          "message": "kubelet is healthy"
        },
        {
          "type": "FrequentContainerdRestart",
          "reason": "ContainerdIsHealthy",
          "message": "containerd is healthy"
        }
      ],
      "rules": [
        {
          "type": "permanent",
          "condition": "FrequentKubeletRestart",
          "reason": "FrequentKubeletRestart",
          "pattern": "kubelet\\\\.service: Start request repeated too quickly\\\\."
        },
        {
          "type": "permanent",
          "condition": "FrequentContainerdRestart",
          "reason": "FrequentContainerdRestart",
          "pattern": "containerd\\\\.service: Start request repeated too quickly\\\\."
        }
      ]
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-problem-detector
  namespace: kube-system
  labels:
    app: node-problem-detector
spec:
  selector:
    matchLabels:
      app: node-problem-detector
  template:
    metadata:
      labels:
        app: node-problem-detector
    spec:
      serviceAccountName: node-problem-detector
      terminationGracePeriodSeconds: 30
      hostNetwork: true
      hostPID: true
      tolerations:
      - operator: Exists
        effect: NoSchedule
      - operator: Exists
        effect: NoExecute
      containers:
      - name: node-problem-detector
        image: $NPD_IMAGE
        imagePullPolicy: IfNotPresent
        command:
        - /node-problem-detector
        - --logtostderr
        - --config.system-log-monitor=/config/kernel-monitor.json,/config/docker-monitor.json,/config/systemd-monitor.json
        - --config.system-stats-monitor=/config/system-stats-monitor.json
        securityContext:
          privileged: true
        resources:
          requests:
            cpu: 10m
            memory: 80Mi
          limits:
            cpu: 100m
            memory: 200Mi
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: log
          mountPath: /var/log
          readOnly: true
        - name: kmsg
          mountPath: /dev/kmsg
          readOnly: true
        - name: localtime
          mountPath: /etc/localtime
          readOnly: true
        - name: config
          mountPath: /config
          readOnly: true
        - name: journal
          mountPath: /var/log/journal
          readOnly: true
      volumes:
      - name: log
        hostPath:
          path: /var/log
      - name: kmsg
        hostPath:
          path: /dev/kmsg
      - name: localtime
        hostPath:
          path: /etc/localtime
      - name: config
        configMap:
          name: node-problem-detector-config
      - name: journal
        hostPath:
          path: /var/log/journal
          type: DirectoryOrCreate
EOF
}

sub install_npd {
    log_info("Installing node-problem-detector $NPD_VERSION...");
    my $manifest = create_npd_manifest();
    my $manifest_file = "/tmp/npd-$$.yaml";

    open my $fh, '>', $manifest_file or die "Cannot write manifest: $!";
    print $fh $manifest;
    close $fh;

    my ($rc, $out) = kubectl("apply -f $manifest_file");
    unlink $manifest_file;

    if ($rc != 0) {
        log_error("Failed to apply NPD manifest: $out");
        return 0;
    }
    log_ok("node-problem-detector manifest applied");
    return 1;
}

sub wait_for_npd {
    my ($timeout) = @_; $timeout //= 120;
    log_info("Waiting for node-problem-detector pods (timeout: ${timeout}s)...");

    for (my $i = 0; $i < $timeout; $i += 10) {
        my ($rc, $ready) = kubectl("get daemonset node-problem-detector -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null");
        my ($rc2, $desired) = kubectl("get daemonset node-problem-detector -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null");
        $ready = int($ready // 0); $desired = int($desired // 0);
        if ($ready > 0 && $ready == $desired) {
            log_ok("All $ready/$desired pods ready");
            return 1;
        }
        print ".";
        sleep 10;
    }
    print "\n";
    log_warn("NPD pods not all ready within ${timeout}s");
    return 0;
}

sub show_node_conditions {
    log_info("Current node conditions from NPD:");
    my @conditions = qw(KernelDeadlock ReadonlyFilesystem FrequentKubeletRestart FrequentContainerdRestart);
    for my $cond (@conditions) {
        my ($rc, $out) = kubectl("get nodes -o jsonpath='{range .items[*]}{.metadata.name}: $cond={.status.conditions[?(\@.type==\"$cond\")].status}\\n{end}' 2>/dev/null");
        if ($out =~ /\S/) {
            $out =~ s/\n$//;
            for my $line (split /\n/, $out) {
                next unless $line =~ /\S/;
                my $status = $line =~ /=False/ ? "OK" : ($line =~ /=True/ ? "PROBLEM" : "N/A");
                print "  $line ($status)\n" if $line =~ /=/;
            }
        }
    }
}

sub show_recent_events {
    log_info("Recent NPD events:");
    my ($rc, $out) = kubectl("get events -n default --field-selector source=node-problem-detector --sort-by='.lastTimestamp' 2>/dev/null | tail -10");
    if ($out =~ /\S/ && $out !~ /No resources/) {
        print "$out\n";
    } else {
        print "  No recent events (this is good!)\n";
    }
}

# Main
print "=" x 60 . "\n";
print "Kubernetes Node Problem Detector Installer\n";
print "=" x 60 . "\n\n";

check_root();
check_control_plane();

if ($UNINSTALL) {
    uninstall_npd();
    exit 0;
}

my ($exists, $ready, $desired) = check_npd_exists();

if ($exists && $ready == $desired && $ready > 0 && !$FORCE) {
    log_ok("node-problem-detector already installed and running");
    print "\n";
    show_node_conditions();
    print "\n";
    show_recent_events();
    print "\nUse --force to reinstall or --uninstall to remove.\n";
    exit 0;
}

if ($exists && $FORCE) {
    log_info("Force reinstall requested");
    uninstall_npd();
}

unless (install_npd()) {
    log_error("Failed to install node-problem-detector");
    exit 1;
}

unless (wait_for_npd(120)) {
    log_warn("Some pods may not be ready. Checking logs...");
    my $logs = get_npd_logs();
    if ($logs =~ /error|failed/i) {
        log_warn("Errors in logs:\n$logs");
    }
}

# Wait a bit for conditions to propagate
log_info("Waiting for conditions to propagate to nodes...");
sleep 15;

print "\n" . "=" x 60 . "\n";
log_ok("node-problem-detector installed!");
print "=" x 60 . "\n\n";

show_node_conditions();
print "\n";
show_recent_events();

print "\nUseful commands:\n";
print "  kubectl get nodes -o custom-columns='NAME:.metadata.name,KERNEL_DEADLOCK:.status.conditions[?(\@.type==\"KernelDeadlock\")].status'\n";
print "  kubectl describe node <node-name> | grep -A5 Conditions\n";
print "  kubectl logs -n kube-system -l app=node-problem-detector\n";
