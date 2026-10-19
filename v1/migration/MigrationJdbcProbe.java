import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

/** 실행 중 BE 이미지의 JDBC 드라이버로 독립 ProxySQL의 대기·재개를 검사한다. DB 쓰기는 하지 않는다. */
public class MigrationJdbcProbe {
    private static Connection connect() throws Exception {
        return DriverManager.getConnection(System.getenv("PROBE_JDBC_URL"),
                System.getenv("SPRING_DATASOURCE_USERNAME"), System.getenv("SPRING_DATASOURCE_PASSWORD"));
    }

    private static int server(Connection connection) throws Exception {
        // 실제 테이블을 읽어 InnoDB 트랜잭션도 시작하도록 한다.
        try (var statement = connection.prepareStatement("SELECT @@server_id, id FROM meetings LIMIT 1");
             ResultSet rows = statement.executeQuery()) {
            if (!rows.next()) throw new IllegalStateException("meetings fixture is empty");
            return rows.getInt(1);
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new IllegalStateException(message);
    }

    private static CompletableFuture<Integer> asyncServer(Connection connection) {
        return CompletableFuture.supplyAsync(() -> {
            try { return server(connection); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
    }

    public static void main(String[] args) throws Exception {
        // Python 검증기와 동일한 리허설 식별자를 사용한다.
        int sourceId = Integer.parseInt(System.getenv().getOrDefault("PROBE_SOURCE_SERVER_ID", "1"));
        int targetId = Integer.parseInt(System.getenv().getOrDefault("PROBE_TARGET_SERVER_ID", "6"));
        Class.forName("com.mysql.cj.jdbc.Driver");
        try (Connection old = connect(); Connection reused = connect(); Connection fresh = connect()) {
            var control = new BufferedReader(new InputStreamReader(System.in));
            require(server(reused) == sourceId, "reused session did not start in source");
            // Hibernate에서 사용하는 읽기 전용·격리 수준 변경도 포함한다.
            reused.setReadOnly(true);
            require(server(reused) == sourceId, "read-only initialization failed");
            reused.setReadOnly(false);
            old.setTransactionIsolation(Connection.TRANSACTION_READ_COMMITTED);
            old.setAutoCommit(false);
            require(server(old) == sourceId, "old transaction did not start in source");
            // 관리자 포트는 MySQL SQL 전체를 구현하지 않으므로 외부 mysql 클라이언트로 제어한다.
            System.out.println("JDBC_READY_FOR_ROUTE");
            require("CONTINUE".equals(control.readLine()), "route control failed");
            var freshResult = asyncServer(fresh);
            var reusedResult = asyncServer(reused);
            Thread.sleep(1000);
            require(!freshResult.isDone() && !reusedResult.isDone(), "new JDBC requests did not wait");
            require(server(old) == sourceId, "active JDBC transaction moved away from source");
            old.commit();
            System.out.println("JDBC_OLD_COMMIT_OK_WHILE_NEW_WAIT");
            var afterCommit = asyncServer(old);
            Thread.sleep(1000);
            require(!afterCommit.isDone(), "next JDBC transaction did not wait");
            System.out.println("JDBC_READY_FOR_OPEN");
            require("CONTINUE".equals(control.readLine()), "open control failed");
            require(freshResult.get(23, TimeUnit.SECONDS) == targetId, "fresh JDBC session did not resume in rehearsal target");
            require(reusedResult.get(23, TimeUnit.SECONDS) == targetId, "reused JDBC session did not resume in rehearsal target");
            require(afterCommit.get(23, TimeUnit.SECONDS) == targetId, "next JDBC transaction did not resume in rehearsal target");
            old.commit();
            System.out.println("JDBC_PASS fresh,reused,after_commit -> rehearsal target; prepared SELECT and session settings");
        }
    }
}
