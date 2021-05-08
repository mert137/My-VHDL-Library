-- This UART supports up to 10 Mbit baud rate but it is recommended to set baud as at least 0.2 of clock frequency.
-- Set 

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity Uart is
    generic (
        BAUDRATE            : integer := 115200;
        CLKFREQ             : integer := 100e6;   
        DATA_WIDTH          : integer := 8
    );
    port (
        clk         	    : in  std_logic;
        m_axis_tdata        : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tready       : in  std_logic;
        m_axis_tvalid       : out std_logic;
        s_axis_tdata        : in std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tready       : out  std_logic;
        s_axis_tvalid       : in std_logic;
        rxd                 : in  std_logic;
        txd                 : out  std_logic
    );
end Uart;

architecture rtl of Uart is
    ---------------------------------------------------------------------------
    -- Filter Length constant
    ---------------------------------------------------------------------------   
    constant rxd_filter_length          : integer  := CLKFREQ / BAUDRATE;
    constant rxd_filter_size            : positive := 10; 
    
    ---------------------------------------------------------------------------
    -- Baud generation constants
    ---------------------------------------------------------------------------
    constant c_tx_div           : integer := CLKFREQ / BAUDRATE;
    ---------------------------------------------------------------------------
    -- Baud generation signals
    ---------------------------------------------------------------------------
    signal tx_baud_counter      : integer range 0 to c_tx_div := 0;   
    
    ---------------------------------------------------------------------------
    -- Transmitter constants
    ---------------------------------------------------------------------------
    
    constant uart_tx_count_size : positive := 3;    -- log2(DATA_WIDTH) = 3
     
    ---------------------------------------------------------------------------
    -- Transmitter signals
    ---------------------------------------------------------------------------
    type uart_tx_states is ( 
        tx_wait_start_bit,
        tx_send_data
    );             
    signal uart_tx_state        : uart_tx_states := TX_WAIT_START_BIT;
    signal uart_tx_data_vec     : std_logic_vector(DATA_WIDTH downto 0) := (others => '0'); 
    signal uart_tx_data         : std_logic_vector((DATA_WIDTH - 1) downto 0) := (others => '0');
    signal uart_tx              : std_logic := '1';
    signal uart_tx_ready        : std_logic := '0';
    signal uart_tx_start        : std_logic := '0';
    signal uart_tx_count        : unsigned(uart_tx_count_size downto 0) := (others => '0'); 
    
    ---------------------------------------------------------------------------
    -- Receiver constants
    ---------------------------------------------------------------------------   
    constant uart_rx_count_size : positive := 3;
    
    ---------------------------------------------------------------------------
    -- Receiver signals
    ---------------------------------------------------------------------------
    type uart_rx_states is ( 
        RX_IDLE,
        ACTIVATE_DATA,
        RX_GET_STOP_BIT
    );      
    signal state                : uart_rx_states := RX_IDLE;
    signal uart_rx_data_vec     : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal uart_rx_count        : unsigned(uart_rx_count_size downto 0) := (others => '0');
    signal rx_data_valid_buf 	: std_logic := '0';
    signal uart_rx_bit_spacing  : unsigned (rxd_filter_size - 1 downto 0) := (others => '0');

begin
    
    
    -- tx outputs
    s_axis_tready <= uart_tx_ready;
    txd <= uart_tx;

    -- tx inputs
    uart_tx_data <= s_axis_tdata;
    uart_tx_start <= s_axis_tvalid;
    
    -- rx outputs
    m_axis_tdata <= uart_rx_data_vec;
    m_axis_tvalid  <= rx_data_valid_buf;

----------------------------------------------------------------------------------------------
    -- UART_RECEIVE_DATA
----------------------------------------------------------------------------------------------
    uart_receive_data   : process(clk)
    begin
        if rising_edge(clk) then         
			rx_data_valid_buf <= '0';
            case state is
----------------------------------------------------------------------------------------------
                when RX_IDLE =>  
                    uart_rx_bit_spacing <= (others => '0');                 	
                    uart_rx_data_vec <= (others => '0');
                    uart_rx_count <= (others => '0');

                    if(rxd = '0') then
                       state <= ACTIVATE_DATA;
                    end if;
    
-----------------------------------------------------------------------------------------------
                when ACTIVATE_DATA =>    
                    uart_rx_bit_spacing <= uart_rx_bit_spacing + 1;
                    if(uart_rx_bit_spacing = rxd_filter_length / 2) then
                        uart_rx_data_vec(uart_rx_data_vec'high) <= rxd;
                        uart_rx_data_vec(uart_rx_data_vec'high-1 downto 0) <= uart_rx_data_vec(uart_rx_data_vec'high downto 1);  
                    end if;

                    if(uart_rx_bit_spacing = (rxd_filter_length - 1)) then
                        uart_rx_bit_spacing <= (others => '0');
                        if (uart_rx_count < 8) then
                            uart_rx_count <= uart_rx_count + 1;
                        else
                            uart_rx_count <= (others => '0');
                            state <= RX_GET_STOP_BIT;
                        end if;
                    end if;
                              
---------------------------------------------------------------------------------------------------       
                when RX_GET_STOP_BIT =>
                    rx_data_valid_buf <= '1';  
                    if(m_axis_tready = '1') then
                        state <= RX_IDLE;  
                    end if;
                when others =>
                    state <= RX_IDLE;
            end case;
        end if;
    end process uart_receive_data; 
    

----------------------------------------------------------------------------------------------
    -- UART_SEND_DATA
----------------------------------------------------------------------------------------------
    uart_send_data : process(clk)
    begin
        if rising_edge(clk) then
            case uart_tx_state is
---------------------------------------------------------------------------------------------------       
                when TX_WAIT_START_BIT =>
                    uart_tx  <= '1'; -- Idle 
                    if (uart_tx_start = '1') then
                        uart_tx_ready <= '0';
                        uart_tx_state <= TX_SEND_DATA;
                        uart_tx_data_vec <= "1"& uart_tx_data; -- Stop + data + Start bits
                        uart_tx <= '0';
                        tx_baud_counter <= (c_tx_div - 1); 
                        uart_tx_count <= (others => '0');
                    end if;
---------------------------------------------------------------------------------------------------       
                when TX_SEND_DATA =>
                    if tx_baud_counter = 0 then
                        tx_baud_counter <= (c_tx_div - 1); 
                        if (uart_tx_count < DATA_WIDTH + 1) then
                            uart_tx_count <= uart_tx_count + 1;
                            uart_tx <= uart_tx_data_vec(0);
                            uart_tx_data_vec(uart_tx_data_vec'high - 1 downto 0) <= uart_tx_data_vec(uart_tx_data_vec'high downto 1);                                
                        else
                            uart_tx_state <= TX_WAIT_START_BIT;
                            uart_tx_ready <= '1';
                        end if;
                    else
                        tx_baud_counter <= tx_baud_counter - 1;
                    end if;
                --------------------------------------------------------------------------
                when others =>
                    uart_tx_state <= TX_WAIT_START_BIT;
            end case;
            end if;
    end process uart_send_data;    
end rtl;
