// Tiny HTTP health-check probe for Docker HEALTHCHECK.
//
// game/questions ship as Paketo Buildpacks "tiny" images (paketobuildpacks/*-run-tiny):
// no shell, no coreutils, no curl/wget — the normal `curl -f http://...` healthcheck
// pattern can't exec anything. What IS present is the JRE the app itself runs on
// (Paketo's bellsoft-liberica buildpack), so this probe is plain JDK code with no
// third-party deps, invoked by running the JRE directly against this file's
// precompiled .class (see HealthCheck.class / README.md in this directory — the JRE
// bundled in these images has no jdk.compiler module, so `java Foo.java` source-launch
// does not work here; it must be precompiled).
//
// Usage: HealthCheck <url>
// Exits 0 if the URL responds 200 with a body containing "UP" (Spring Boot Actuator's
// health status for a healthy app), non-zero otherwise.
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.URI;
import java.time.Duration;

public class HealthCheck {
    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: HealthCheck <url>");
            System.exit(2);
            return;
        }
        try {
            HttpClient client = HttpClient.newBuilder()
                    .connectTimeout(Duration.ofSeconds(3))
                    .build();
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(args[0]))
                    .timeout(Duration.ofSeconds(3))
                    .GET()
                    .build();
            HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
            String body = response.body() == null ? "" : response.body();
            if (response.statusCode() == 200 && body.contains("\"UP\"")) {
                System.exit(0);
            }
            System.err.println("unhealthy: status=" + response.statusCode() + " body=" + body);
            System.exit(1);
        } catch (Exception e) {
            System.err.println("healthcheck error: " + e);
            System.exit(1);
        }
    }
}
