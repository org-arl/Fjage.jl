package org.arl.fjage.stress;

import org.arl.fjage.Message;
import org.arl.fjage.Performative;

/** Tally reply from the Java stress agent; flat fields for easy inflation on the Julia side. */
public class StressStats extends Message {
  private static final long serialVersionUID = 1L;
  public long bcastSent = 0;
  public String[] dmPeers = new String[0];
  public long[] dmSent = new long[0];
  public String[] senders = new String[0];
  public long[] recvBcast = new long[0];
  public long[] recvDm = new long[0];
  public long dups = 0;
  public long latN = 0;
  public long latSum = 0;
  public long latMin = 0;
  public long latMax = 0;
  public StressStats() {
    super(Performative.INFORM);
  }
  public StressStats(Message inReplyTo) {
    super(inReplyTo, Performative.INFORM);
  }
}
