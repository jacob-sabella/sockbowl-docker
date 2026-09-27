# HealthCheck.java

A minimal HTTP health probe used by `sockbowl-game` and `sockbowl-questions`'
Docker healthchecks (see `docker-compose.yml`).

## Why this exists

Those two images are built by Spring Boot's `bootBuildImage` (Paketo Buildpacks) onto
a `paketobuildpacks/*-run-tiny` base — there is no shell, no coreutils, and no
curl/wget in the running container, so the usual
`test: ["CMD-SHELL", "curl -f http://localhost:.../actuator/health || exit 1"]`
pattern can't exec anything at all. The one thing that *is* guaranteed to be there is
the JRE the app itself runs on, at a path the `bellsoft-liberica` Paketo buildpack
lays down deterministically:

```
/layers/paketo-buildpacks_bellsoft-liberica/jre/bin/java
```

(Cloud Native Buildpacks put each buildpack's layers at `/layers/<buildpack-id with
`/` → `_`>/<layer-name>`; that path is a function of the buildpack id and layer name,
not the JDK version installed under it, so it should survive a Java version bump — but
it's still an internal detail of the current buildpack setup and CAN change if
game/questions ever switch away from `bootBuildImage`/Paketo. If a game/questions
healthcheck ever goes permanently unhealthy right after a build/tooling change there,
re-derive the path with:
`cid=$(docker create <image>); docker export "$cid" | tar -tv | grep 'bin/java$'; docker rm "$cid"`
and update the `test:` line in `docker-compose.yml`.)

So the healthcheck runs that JRE directly against a tiny precompiled health-probe
class that does a plain `java.net.http` GET against the app's own
`/actuator/health` and checks for a 200 with `"UP"` in the body — no third-party
dependencies, nothing to install.

## Why a committed `.class` and not `java HealthCheck.java` (source-launch)

JDK 11+'s single-file source-launch (`java Foo.java`) needs the `jdk.compiler` module,
but these images ship a JRE-only Bellsoft Liberica distribution
(`Module jdk.compiler not in boot Layer` if you try). So `HealthCheck.class` is
compiled ahead of time and mounted in read-only; only the JVM (no compiler) is needed
to run it.

## Rebuilding

If you change `HealthCheck.java`, recompile targeting Java 17 bytecode (the oldest JRE
these images are expected to run; class files are forward-compatible with newer JVMs):

```bash
javac --release 17 -d scripts/healthcheck scripts/healthcheck/HealthCheck.java
```
