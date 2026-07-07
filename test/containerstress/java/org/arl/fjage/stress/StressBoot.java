package org.arl.fjage.stress;

import org.arl.fjage.Platform;
import org.arl.fjage.RealTimePlatform;
import org.arl.fjage.remote.MasterContainer;

/** Boots a master container with Java stress agents j1..jN. Usage: StressBoot [port [nagents [queuesize]]] */
public class StressBoot {
  public static void main(String[] args) throws Exception {
    int port = args.length > 0 ? Integer.parseInt(args[0]) : 5082;
    int n = args.length > 1 ? Integer.parseInt(args[1]) : 1;
    int qsize = args.length > 2 ? Integer.parseInt(args[2]) : 256;
    Platform platform = new RealTimePlatform();
    MasterContainer container = new MasterContainer(platform, port);
    for (int i = 1; i <= n; i++) {
      JStressAgent a = new JStressAgent();
      a.setQueueSize(qsize);
      container.add("j"+i, a);
    }
    platform.start();
  }
}
