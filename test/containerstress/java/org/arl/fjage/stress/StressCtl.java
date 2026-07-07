package org.arl.fjage.stress;

import org.arl.fjage.Message;
import org.arl.fjage.Performative;

/** Control message for the Java stress agent: start/stop traffic, request stats. */
public class StressCtl extends Message {
  private static final long serialVersionUID = 1L;
  public String cmd = "";               // "start" | "stop" | "stats"
  public double rate = 1.0;             // msgs/agent/s (mean), for "start"
  public long warmup = 0;               // ms before latency collection begins, for "start"
  public boolean churn = false;         // secondary-behavior churn mode, for "start"
  public String[] peers = new String[0];
  public StressCtl() {
    super(Performative.REQUEST);
  }
}
