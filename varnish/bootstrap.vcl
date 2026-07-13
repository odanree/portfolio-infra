vcl 4.1;

# BOOTSTRAP VCL — minimum viable pass-through so Varnish can start before
# the workflow-delivered VCL arrives. Owned by the portfolio-infra repo;
# only touched when the topology itself changes.
#
# The real cache policy (grace mode, PURGE/BAN ACL, cookie-strip, etc.)
# lives in odanree/headless-wp-next → varnish/hetzner.vcl and is delivered
# by .github/workflows/deploy-varnish-hetzner.yml via:
#
#   docker cp default.vcl portfolio-varnish:/etc/varnish/hot.vcl
#   docker exec portfolio-varnish varnishadm vcl.load <label> /etc/varnish/hot.vcl
#   docker exec portfolio-varnish varnishadm vcl.use <label>
#
# If portfolio-varnish gets recreated (docker compose recreate), this
# bootstrap becomes the active VCL again. Re-run the headless-wp-next
# deploy workflow (workflow_dispatch) to restore the full policy.

backend wp {
    .host = "wordpress";
    .port = "80";
    .connect_timeout = 2s;
    .first_byte_timeout = 10s;
    .between_bytes_timeout = 5s;
}

sub vcl_recv {
    # Pass-through only. No caching in the bootstrap — real policy comes
    # from the deploy workflow.
    return (pass);
}
