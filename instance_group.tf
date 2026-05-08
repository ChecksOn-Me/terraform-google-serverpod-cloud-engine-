# Template for instances running Serverpod's Docker container.

resource "google_compute_instance_template" "serverpod" {
  name        = "serverpod-${var.runmode}-template"
  description = "Instance template for Serverpod's Docker container."

  machine_type = var.machine_type

  disk {
    source_image = "cos-cloud/cos-stable"
  }

  # Startup script that runs the Serverpod Docker container.
  metadata_startup_script = var.startup_script_override != "" ? var.startup_script_override : <<-EOF
      #!/bin/bash
      set -euo pipefail

      for i in {1..30}; do
        if docker info >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done

      # Ensure serverpod-user exists (backward compatibility)
      useradd serverpod-user 2>/dev/null || true
      usermod -aG docker serverpod-user 2>/dev/null || true

      # Clean up any existing container before starting a new one.
      docker rm -f serverpod-${var.runmode} >/dev/null 2>&1 || true

      # Configure Docker credential helper for Artifact Registry.
      # On Container-Optimized OS, the root filesystem is read-only,
      # so we use /tmp for the Docker configuration directory.
      mkdir -p /tmp/.docker
      export DOCKER_CONFIG=/tmp/.docker
      docker-credential-gcr configure-docker --registries ${var.region}-docker.pkg.dev

      # Open the host firewall for GCE health-check probes.
      # When using --net host, Docker does not manage iptables automatically.
      if [ "${var.enable_iptables}" = "true" ]; then
        if ! iptables -C INPUT -p tcp --dport 8080 -j ACCEPT >/dev/null 2>&1; then
          iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
        fi
      fi

      # Run the Serverpod container.  --net host is required so that GCE
      # health checks (which probe localhost:8080) can reach the application.
      docker run -d \
        --restart always \
        --net ${var.docker_network_mode} \
        -e runmode=${var.runmode} \
        -e serverid=$(hostname) \
        --name serverpod-${var.runmode} \
        ${var.region}-docker.pkg.dev/${var.project}/serverpod-${var.runmode}-container/serverpod:latest
    EOF

  network_interface {
    network = google_compute_network.serverpod.name
    access_config {
      # Ephemeral public IP.
    }
  }

  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform"]
  }

  tags = ["serverpod-${var.runmode}-instance", "serverpod-${var.runmode}-instance-ssh"]
}

# Instance group manager that runs the Serverpod Docker container, with autoscaling and health checks.

resource "google_compute_instance_group_manager" "serverpod" {
  name = "serverpod-${var.runmode}-group"
  version {
    instance_template = google_compute_instance_template.serverpod.id
  }
  base_instance_name = "serverpod-${var.runmode}"
  zone               = var.zone

  named_port {
    name = "api"
    port = 8080
  }

  named_port {
    name = "insights"
    port = 8081
  }

  named_port {
    name = "web"
    port = 8082
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.serverpod-instance-group.id
    initial_delay_sec = 300
  }
}

resource "google_compute_autoscaler" "serverpod" {
  name   = "serverpod-${var.runmode}-autoscaler"
  zone   = var.zone
  target = google_compute_instance_group_manager.serverpod.id

  autoscaling_policy {
    min_replicas    = var.autoscaling_min_size
    max_replicas    = var.autoscaling_max_size
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }
  }
}

resource "google_compute_health_check" "serverpod-instance-group" {
  name                = "serverpod-${var.runmode}-group-health-check"
  timeout_sec         = 5
  check_interval_sec  = 30
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = "8080"
  }
}