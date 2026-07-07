package org.arl.fjage.stress;

import org.arl.fjage.Message;
import org.arl.fjage.Performative;

/** Stress traffic message; field names must match the Julia StressMsg exactly. */
public class StressMsg extends Message {
  private static final long serialVersionUID = 1L;
  public String stream = "b";   // "b" = broadcast, "d" = directed
  public long seq = 0;          // 1-based, contiguous per (sender, stream[, recipient])
  public long t0 = 0;           // sender wall-clock ms, for latency measurement
  public StressMsg() {
    super(Performative.INFORM);
  }
}
