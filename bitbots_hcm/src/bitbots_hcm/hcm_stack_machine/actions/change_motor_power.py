import rospy 
import humanoid_league_msgs.msg
from bitbots_stackmachine.abstract_action_element import AbstractActionElement
import bitbots_hcm.hcm_stack_machine.hcm_connector
from bitbots_hcm.hcm_stack_machine.hcm_connector import STATE_HARDWARE_PROBLEM

class AbstractChangeMotorPower(AbstractActionElement):
    """
    
    """

    def __init__(self, connector, _):
        super(AbstractChangeMotorPower, self).__init__(connector)
        self.called = False
        self.last_service_call = 0
        self.time_between_calls = 2

    def perform(self, connector, reevaluate=False):        
        raise NotImplementedError

    def call_motor_power_service(self, on):
        #TODO
        pass

class TurnMotorsOn(AbstractChangeMotorPower):

    def perform(self, connector, reevaluate=False):        
        if connector.are_motors_on():
            rospy.logwarn("HCM got motor connection, will resume")
            return self.pop()
        
        if not self.called:
            rospy.logwarn("Turning motors ON!")
            self.called = True
            self.last_service_call = rospy.Time.now()
            self.call_motor_power_service(True)

        # see if we called the service some time ago and the motors are still not giving us states
        if self.called and rospy.Time.now().to_sec() - self.last_service_call.to_sec() > self.time_between_calls:
            connector.current_state = STATE_HARDWARE_PROBLEM
            rospy.logwarn_throttle(5, "Motor power turned ON but HCM does not recieve motor values!")        

class TurnMotorsOff(AbstractChangeMotorPower):

    def perform(self, connector, reevaluate=False):        
        if not connector.are_motors_on():
            return self.pop()
        
        if not self.called:
            rospy.logwarn("Turning motors OFF!")
            self.called = True
            self.last_service_call = rospy.Time.now()
            self.call_motor_power_service(False)

        # see if we called the service some time ago and the motors are still on
        if self.called and rospy.Time.now().to_sec() - self.last_service_call.to_sec() > self.time_between_calls:
            connector.current_state = STATE_HARDWARE_PROBLEM
            rospy.logwarn_throttle(5, "Motor power turned OFF but HCM still recieves motor values!")        