// Untrusted input design: only a convenient way to get a netlist.
// Free-running 27-bit counter, power-up value 0, no reset.
// At 100 MHz the LED period is 2^27 / 1e8 = 1.342 s, 50 % duty.
module blinky (
    input  wire clk,
    output wire led
);
    reg [26:0] cnt = 27'd0;

    always @(posedge clk)
        cnt <= cnt + 27'd1;

    assign led = cnt[26];
endmodule
